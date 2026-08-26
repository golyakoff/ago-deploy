#!/usr/bin/env bash
# Apply k8s/base/keycloak-realm-import.json's *realm-level* settings to a realm that already exists.
#
# Why this script exists (15-01 / ago-root adr/0036):
#
# `--import-realm` is a bootstrap, not a reconciler. Keycloak picks its import strategy from the state
# of the database it boots against - verified live on 2026-08-25 by reading its own startup log:
#
#   first boot, empty database:   KC-SERVICES0030: Full model import requested. Strategy: OVERWRITE_EXISTING
#                                 Realm 'ago-chat' imported
#   every boot after that:        KC-SERVICES0030: Full model import requested. Strategy: IGNORE_EXISTING
#                                 Realm 'ago-chat' already exists. Import skipped
#
# Before `15-01` Keycloak had no database that survived a restart, so every boot was a first boot and
# editing the realm import file did reach the running realm - by destroying and rebuilding it. That
# property is gone on purpose: it is the same property that destroyed every self-registered user.
# "Import skipped" is the correct and wanted behaviour now, and it means a changed realm file needs a
# deliberate step. This is that step.
#
# What it does and does not cover:
#   - Realm-level settings (adr/0034's brute-force thresholds, password policy, OTP parameters and the
#     four token/session lifetimes; registrationAllowed, verifyEmail, sslRequired, and `11-07`'s
#     loginTheme) - yes. PUT
#     /admin/realms/{realm} maps the realm-level fields of the representation and ignores its nested
#     users/clients/roles collections, which is exactly the split wanted here: settings move, accounts
#     do not. Verified live - the runtime-created user present before the run was still present and
#     still able to log in afterwards.
#   - Clients, realm roles, groups, identity providers - NO. Those are nested collections and are
#     ignored by this endpoint, and a restart will not create them either (the whole import is skipped,
#     not merged). Adding or changing one of those on a realm that already exists is a `kcadm.sh
#     create`/`update` against the specific sub-resource, by hand, and it belongs in the same change
#     that edits the JSON.
#   - Deleting a realm-level setting by removing it from the JSON - NO. Absent fields are left alone
#     rather than reset to their default, so a setting that has ever been applied has to be set back
#     explicitly, not deleted from the file.
#   - The realm's `smtpServer` (`10-05`) - NO, and on purpose. It is the one realm-level setting that
#     is not in keycloak-realm-import.json, because it carries a credential and because its correct
#     value differs between the local sink and the real provider. It comes from KEYCLOAK_SMTP_* in the
#     `infra-credentials` Secret instead, applied by k8s/apply-smtp-settings.sh. Since it is absent
#     from the file, the rule above applies and this script leaves the live SMTP configuration alone.
#     Run apply-smtp-settings.sh *after* this script rather than before, and re-run it if in doubt -
#     it is idempotent, and it is always the safe direction.
#
# `11-07` note: `loginTheme` is a plain realm-level field, so this script is all it takes to move the
# login pages onto the AGO theme on a realm that already exists - no bespoke kcadm call. Checked by
# setting loginTheme to something else on a running realm and running exactly the update below: it
# came back to `ago`. Worth knowing because the theme is the one setting whose absence is visible to
# every visitor rather than only in a token.
#
# What it deliberately is not: `kc.sh import --override true`. That would apply the whole file, and it
# does so by replacing the realm - taking every runtime-created user with it. Never run it against a
# realm that has real users in it.
#
# Usage, from anywhere:
#   k8s/apply-realm-settings.sh              # the current kubectl context (local cluster, or the node)
#   k8s/apply-realm-settings.sh compose      # the docker-compose loop
# Environment:
#   REALM   realm to update  (default: ago-chat)
#   NS      namespace        (default: ago-chat, k8s target only)

set -euo pipefail

TARGET="${1:-k8s}"
REALM="${REALM:-ago-chat}"
NS="${NS:-ago-chat}"
# The realm import file as the Keycloak container sees it - a read-only ConfigMap mount under k8s
# (base/keycloak.yaml), a read-only bind mount of the same file under compose (docker-compose.yml).
# Reading it from inside the container is what keeps this script honest: it applies the file that is
# actually mounted into the running Keycloak, not a copy from whatever checkout the script runs from.
IMPORT_FILE="/opt/keycloak/data/import/ago-chat-realm.json"

case "$TARGET" in
  k8s)
    kc() { if command -v kubectl >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
    # -c keycloak because base/keycloak.yaml's pod also has an init container (15-01), so the
    # default-container guess is no longer unambiguous.
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

echo "== applying realm-level settings to '$REALM' ($TARGET) from $IMPORT_FILE"

kcsh "
set -eu
KCADM=/opt/keycloak/bin/kcadm.sh
\$KCADM config credentials --server http://localhost:8080 --realm master \
  --user \"\$KEYCLOAK_ADMIN\" --password \"\$KEYCLOAK_ADMIN_PASSWORD\" >/dev/null
\$KCADM update realms/$REALM -f $IMPORT_FILE
echo '-- realm now reports:'
\$KCADM get realms/$REALM --fields loginTheme,registrationAllowed,resetPasswordAllowed,verifyEmail,bruteForceProtected,failureFactor,passwordPolicy,accessTokenLifespan,ssoSessionIdleTimeout,ssoSessionMaxLifespan,offlineSessionIdleTimeout,actionTokenGeneratedByUserLifespan
"

echo "== done. Users and clients were not touched - see this script's own header for what it does not cover."
