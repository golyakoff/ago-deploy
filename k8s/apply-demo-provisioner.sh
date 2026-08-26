#!/usr/bin/env bash
# `8-07` / ago-root `adr/0058`: finish wiring the `ago-demo-provisioner` client that
# keycloak-realm-import.json declares - set its secret, and grant its service account the one realm
# role it is allowed to hold.
#
# WHY NEITHER HALF IS IN THE REALM IMPORT FILE, where every other client setting lives. The same two
# reasons apply-smtp-settings.sh gives for `smtpServer`, and one more:
#
#   1. The client secret is a credential, and that file is committed and mounted read-only into the pod
#      (`repositories.md`: no secrets, ever - not in a fixture, not in a file meant to be fixed later).
#      It travels the .env -> secretGenerator -> infra-credentials road every other credential travels.
#   2. A service account's *role mapping* is not a field on the client at all - it is a mapping on the
#      generated service-account user, which does not exist until the client does. An import cannot
#      express "grant a role to a user this same import is about to create".
#   3. `adr/0036`: an import is skipped entirely once the realm exists, so anything that has to be
#      applied to a realm already running has to be applied like this regardless.
#
# WHAT THE ROLE IS, AND WHY ONLY THIS ONE. `manage-users` on this realm's own `realm-management`
# client. Not `realm-admin`, and emphatically not the master realm's admin that apply-realm-settings.sh
# uses from this node: the whole argument in `adr/0058` for holding this credential at all is that it
# can create and delete users and do nothing else. Widening it silently would remove that argument
# without removing the sentence claiming it.
#
# Run on the node, after the realm exists:
#   KEYCLOAK_DEMO_PROVISIONER_SECRET=... ./apply-demo-provisioner.sh
#
# Environment:
#   NS                                namespace                     (default: ago-chat)
#   REALM                             realm name                    (default: ago-chat)
#   KEYCLOAK_DEMO_PROVISIONER_SECRET  the client secret to set      (required)
set -euo pipefail

NS="${NS:-ago-chat}"
REALM="${REALM:-ago-chat}"
CLIENT_ID="ago-demo-provisioner"

if [[ -z "${KEYCLOAK_DEMO_PROVISIONER_SECRET:-}" ]]; then
  echo "Set KEYCLOAK_DEMO_PROVISIONER_SECRET - the same value the infra-credentials Secret carries." >&2
  exit 1
fi

kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }

# kcadm inside the Keycloak pod, so no admin credential leaves the cluster and nothing has to be
# port-forwarded - the same shape apply-realm-settings.sh uses.
POD=$(kc get pod -n "$NS" -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
exec_kc() { kc exec -n "$NS" "$POD" -- /opt/keycloak/bin/kcadm.sh "$@"; }

echo "Authenticating kcadm inside $POD..."
exec_kc config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

echo "Setting the $CLIENT_ID client secret..."
CLIENT_UUID=$(exec_kc get clients -r "$REALM" -q "clientId=$CLIENT_ID" --fields id --format csv --noquotes | tail -n1)
if [[ -z "$CLIENT_UUID" ]]; then
  echo "No $CLIENT_ID client in realm $REALM - apply the manifests first so the realm import creates it." >&2
  exit 1
fi
exec_kc update "clients/$CLIENT_UUID" -r "$REALM" -s "secret=$KEYCLOAK_DEMO_PROVISIONER_SECRET" >/dev/null

echo "Granting realm-management:manage-users to its service account..."
# `add-roles --uusername service-account-<clientId>` is Keycloak's own name for the generated user;
# --cclientid names the client the role belongs to, which is what keeps this to one role rather than
# the realm-wide set a bare --rolename would search.
exec_kc add-roles -r "$REALM" \
  --uusername "service-account-$CLIENT_ID" \
  --cclientid realm-management \
  --rolename manage-users >/dev/null

echo "Done. Ago.Chat.Api and Ago.Chat.Worker can now mint and expire demo tenants (adr/0058)."
echo "Ago.Chat.Webhooks deliberately does not receive this secret."
