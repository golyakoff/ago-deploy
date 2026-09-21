#!/usr/bin/env bash
# `26-11`: finish wiring the `ago-android` client that keycloak-realm-import.json declares onto a
# realm that already exists.
#
# WHY THIS SCRIPT EXISTS. `adr/0036`: `--import-realm` is skip-if-exists - once the realm exists,
# keycloak-realm-import.json is never read again, on restart or on redeploy. The demo realm was
# created long before this client was added to the file, so the file's own declaration of
# `ago-android` will never reach it by itself. `8-07` hit exactly this with `ago-demo-provisioner`
# (`apply-demo-provisioner.sh`'s own header tells that story); this script follows its shape.
#
# UNLIKE `ago-demo-provisioner`, this client has no secret and no service account - it is a public
# client with PKCE, so there is nothing to configure after creation beyond the client itself and its
# one protocol mapper. That also makes this script simpler to make idempotent: with no secret to
# reset on every run, "already exists" really does mean "nothing to do".
#
# Run on the node, after the realm exists:
#   ./apply-android-client.sh
#
# Environment:
#   NS      namespace       (default: ago-chat)
#   REALM   realm name      (default: ago-chat)
set -euo pipefail

NS="${NS:-ago-chat}"
REALM="${REALM:-ago-chat}"
CLIENT_ID="ago-android"
MAPPER_NAME="ago-android-audience"
# The exact value Ago.Chat.Api/CompositionRoot.cs validates today (Auth:Keycloak:Audience default,
# ago-root docs/backlog/26-11). Not a new audience - the whole trick of this item is presenting a
# credential the resource server already accepts, with zero changes to ago-chat.
AUDIENCE="ago-console"
REDIRECT_URI="ago-android://callback"

kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }

# kcadm inside the Keycloak pod, so no admin credential leaves the cluster and nothing has to be
# port-forwarded - the same shape apply-realm-settings.sh and apply-demo-provisioner.sh use.
POD=$(kc get pod -n "$NS" -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
exec_kc() { kc exec -n "$NS" "$POD" -- /opt/keycloak/bin/kcadm.sh "$@"; }

echo "Authenticating kcadm inside $POD..."
exec_kc config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

CLIENT_UUID=$(exec_kc get clients -r "$REALM" -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -n1)

if [[ -z "$CLIENT_UUID" ]]; then
  # Mirrors keycloak-realm-import.json's own entry. `name` and `description` are set in a second
  # call, not here: apply-demo-provisioner.sh found that kcadm's `-s key=value` cannot carry a
  # client's `description` on create - the whole create answers a bare `unknown_error`, and the
  # identical create minus that one flag succeeds (docs/runbooks/realm-operations.md). Dropping the
  # longest text field from the create avoids that here too.
  echo "No $CLIENT_ID client in realm $REALM yet - creating it..."
  exec_kc create clients -r "$REALM" \
    -s "clientId=$CLIENT_ID" \
    -s 'enabled=true' \
    -s 'publicClient=true' \
    -s 'standardFlowEnabled=true' \
    -s 'implicitFlowEnabled=false' \
    -s 'directAccessGrantsEnabled=false' \
    -s 'serviceAccountsEnabled=false' \
    -s 'protocol=openid-connect' \
    -s "redirectUris=[\"$REDIRECT_URI\"]" \
    -s 'attributes."pkce.code.challenge.method"=S256' >/dev/null
  CLIENT_UUID=$(exec_kc get clients -r "$REALM" -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -n1)
  if [[ -z "$CLIENT_UUID" ]]; then
    echo "Created $CLIENT_ID but could not read it back - stopping rather than guessing." >&2
    exit 1
  fi
  exec_kc update "clients/$CLIENT_UUID" -r "$REALM" \
    -s 'name=AGO Android app (26-11)' >/dev/null
  echo "Created $CLIENT_ID ($CLIENT_UUID)."
else
  echo "$CLIENT_ID already exists in realm $REALM ($CLIENT_UUID) - leaving the client alone."
fi

echo "Checking the $MAPPER_NAME protocol mapper..."
MAPPER_EXISTS=$(exec_kc get "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" \
  --fields name --format csv --noquotes | grep -Fxc "$MAPPER_NAME" || true)

if [[ "$MAPPER_EXISTS" -eq 0 ]]; then
  echo "Adding the $MAPPER_NAME audience mapper (audience: $AUDIENCE)..."
  exec_kc create "clients/$CLIENT_UUID/protocol-mappers/models" -r "$REALM" \
    -s "name=$MAPPER_NAME" \
    -s 'protocol=openid-connect' \
    -s 'protocolMapper=oidc-audience-mapper' \
    -s "config.\"included.client.audience\"=$AUDIENCE" \
    -s 'config."id.token.claim"=false' \
    -s 'config."access.token.claim"=true' >/dev/null
  echo "Added."
else
  echo "$MAPPER_NAME already present - leaving it alone."
fi

echo "Done. $CLIENT_ID can now run Authorization Code + PKCE and receive a token aud=$AUDIENCE that"
echo "Ago.Chat.Api already validates - see docs/runbooks/realm-operations.md for the by-hand proof."
