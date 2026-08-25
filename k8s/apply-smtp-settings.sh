#!/usr/bin/env bash
# Point the Keycloak realm's `smtpServer` at whatever mail path this environment has, using the
# KEYCLOAK_SMTP_* values already present in the Keycloak container's own environment.
#
# Why this exists at all (10-05 / ago-root adr/0040):
#
# The realm has had `verifyEmail: true` since `10-01`/`adr/0028` and `smtpServer: null` for just as
# long, so every self-registration ended with `SEND_VERIFY_EMAIL_ERROR ... error="email_send_failed"`
# in Keycloak's own log, an account that existed, and a required action that could never be lifted. No
# real visitor could finish signing up. Password reset was broken for the identical reason.
#
# Why the SMTP settings are NOT in keycloak-realm-import.json, where every other realm setting lives:
#
#   1. The password is a credential. `repositories.md`: no secrets, ever - not in a fixture, not in a
#      file meant to be fixed later. That file is committed and is mounted read-only into the pod.
#   2. Even the non-secret half must differ per environment: locally it is a sink that swallows
#      everything (mailpit), publicly it is a real provider that charges per message. A single
#      committed value would be wrong in one of the two places, and the failure mode of being wrong in
#      the public direction is "real verification mail is accepted and silently dropped", which is
#      worse than not sending at all.
#   3. `apply-realm-settings.sh` PUTs that whole file's realm-level fields onto the live realm. If
#      `smtpServer` were in it, running that script against the demo would reset the demo's mail
#      configuration to the local sink. Keeping SMTP out of the file makes that impossible rather than
#      merely discouraged: absent fields are left alone by that endpoint (its own header says so).
#
# So SMTP travels the same road every other credential in this deployment already travels - `.env` ->
# kustomize `secretGenerator` -> the `infra-credentials` Secret -> `envFrom` on the Keycloak container
# (k8s/base/keycloak.yaml) - and this script is what turns those variables into a realm setting.
# Keycloak itself never reads them; SMTP is realm state, not server configuration.
#
# Usage, from anywhere:
#   k8s/apply-smtp-settings.sh              # the current kubectl context (local cluster, or the node)
#   k8s/apply-smtp-settings.sh compose      # the docker-compose loop
# Environment:
#   REALM   realm to update  (default: ago-chat)
#   NS      namespace        (default: ago-chat, k8s target only)
#
# Run it after `apply-realm-settings.sh`, never before - see the note at the bottom of this header.
#
# Which KEYCLOAK_SMTP_* keys are read (all from the container, not from this shell):
#   KEYCLOAK_SMTP_HOST               required
#   KEYCLOAK_SMTP_FROM               required - the envelope/header sender address
#   KEYCLOAK_SMTP_PORT               default 25
#   KEYCLOAK_SMTP_FROM_DISPLAY_NAME  optional
#   KEYCLOAK_SMTP_REPLY_TO           optional
#   KEYCLOAK_SMTP_ENVELOPE_FROM      optional - set it if the provider requires a bounce address that
#                                    differs from the visible From (that is what DMARC alignment and
#                                    bounce routing are actually keyed on)
#   KEYCLOAK_SMTP_STARTTLS           true/false, default false
#   KEYCLOAK_SMTP_SSL                true/false, default false  (implicit TLS, usually port 465)
#   KEYCLOAK_SMTP_AUTH               true/false, default false
#   KEYCLOAK_SMTP_USER               required when auth is true
#   KEYCLOAK_SMTP_PASSWORD           required when auth is true
#
# Every one of them is written on every run, including the ones left empty, so that what the realm ends
# up with is exactly what this environment says and nothing is inherited from an earlier run. Checked
# rather than assumed while building this: the endpoint replaces the whole `smtpServer` map rather than
# merging keys into it (a second apply that omitted `fromDisplayName` removed it), so the two
# behaviours agree here - but only because the full set is always written.
#
# ORDERING with apply-realm-settings.sh - checked, because it looked like a trap and is not one.
# That script does a read-modify-write of the whole realm representation, and Keycloak returns the SMTP
# password masked as `**********` in the read half, so the obvious worry is that the write half stores
# the mask as the real password and silently breaks sending. Tested directly (compose target, a known
# probe password read straight out of Keycloak`s own `realm_smtp_config` table before and after):
# the password survived intact. Keycloak recognises its own mask and keeps the stored value. Either
# order is therefore safe. This script is idempotent regardless - when in doubt, run it again.

set -euo pipefail

TARGET="${1:-k8s}"
REALM="${REALM:-ago-chat}"
NS="${NS:-ago-chat}"

case "$TARGET" in
  k8s)
    kc() { if command -v kubectl >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
    # -c keycloak because the pod also has an init container since `15-01`, so the default-container
    # guess is no longer unambiguous.
    kcsh() { kc exec -n "$NS" deploy/keycloak -c keycloak -- sh -c "$1"; }
    ;;
  compose)
    COMPOSE_FILE="$(cd "$(dirname "$0")/../docker" && pwd)/docker-compose.yml"
    kcsh() { docker compose -f "$COMPOSE_FILE" exec -T keycloak sh -c "$1"; }
    ;;
  *)
    echo "usage: $0 [k8s|compose]" >&2
    exit 2
    ;;
esac

echo "== applying smtpServer to realm '$REALM' ($TARGET) from the Keycloak container's KEYCLOAK_SMTP_* environment"

kcsh '
set -eu

: "${KEYCLOAK_SMTP_HOST:?not set in the Keycloak container - add KEYCLOAK_SMTP_* to the .env feeding infra-credentials (see .env.example) and restart Keycloak so the Secret is re-read}"
: "${KEYCLOAK_SMTP_FROM:?not set - the realm needs a sender address before Keycloak will send anything}"

PORT="${KEYCLOAK_SMTP_PORT:-25}"
STARTTLS="${KEYCLOAK_SMTP_STARTTLS:-false}"
SSL="${KEYCLOAK_SMTP_SSL:-false}"
AUTH="${KEYCLOAK_SMTP_AUTH:-false}"
USER_="${KEYCLOAK_SMTP_USER:-}"
PASS_="${KEYCLOAK_SMTP_PASSWORD:-}"

if [ "$AUTH" = "true" ] && { [ -z "$USER_" ] || [ -z "$PASS_" ]; }; then
  echo "KEYCLOAK_SMTP_AUTH=true but KEYCLOAK_SMTP_USER/KEYCLOAK_SMTP_PASSWORD is empty" >&2
  exit 1
fi

# JSON string escaping for values that are outside this repository entirely (a generated provider
# password can legitimately contain a quote or a backslash). Backslashes first, then quotes.
esc() { printf %s "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/\"/\\\\\"/g"; }

KCADM=/opt/keycloak/bin/kcadm.sh
$KCADM config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# Fed on stdin rather than as -s key=value arguments, so the password never appears in the process
# table of the container - the same instinct the init container in base/keycloak.yaml already follows,
# passing its password to psql as a variable instead of interpolating it into SQL text.
$KCADM update "realms/'"$REALM"'" -f - <<JSON
{
  "smtpServer": {
    "host": "$(esc "$KEYCLOAK_SMTP_HOST")",
    "port": "$(esc "$PORT")",
    "from": "$(esc "$KEYCLOAK_SMTP_FROM")",
    "fromDisplayName": "$(esc "${KEYCLOAK_SMTP_FROM_DISPLAY_NAME:-}")",
    "replyTo": "$(esc "${KEYCLOAK_SMTP_REPLY_TO:-}")",
    "envelopeFrom": "$(esc "${KEYCLOAK_SMTP_ENVELOPE_FROM:-}")",
    "starttls": "$(esc "$STARTTLS")",
    "ssl": "$(esc "$SSL")",
    "auth": "$(esc "$AUTH")",
    "user": "$(esc "$USER_")",
    "password": "$(esc "$PASS_")"
  }
}
JSON

echo "-- realm now reports:"
# Not `--fields smtpServer`: kcadm`s field filter does not descend into a Map-valued field and prints
# an empty object for it, which reads exactly like "nothing was applied" while the setting is in fact
# there (found that way while verifying this script - the update had worked and the check was lying).
# Read the whole representation and cut the block out instead.
$KCADM get "realms/'"$REALM"'" | sed -n "/\"smtpServer\"/,/^  }/p"
'

echo "== done. Send a real message through it rather than trusting this output: register through the"
echo "   hosted form, or trigger a password reset, and watch the mail arrive."
