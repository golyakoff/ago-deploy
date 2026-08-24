#!/usr/bin/env bash
# Creates the demo site and operator (backlog/0-03-local-infrastructure.md's seed/ note; the schema
# this needs arrived with 1-04), plus a second, independent site and operator (`8-02`) for
# demonstrating tenant isolation live. Idempotent - fixed, well-known ids and ON CONFLICT DO NOTHING
# mean running this twice never creates a duplicate of either site.
#
# Neither printed value is a secret: the site's public_key identifies a tenant and grants nothing
# beyond starting a visitor session (api-design.md); the operator id resolves from Keycloak's own
# token via OperatorIdentityClaimsTransformation (5-05, adr/0022) - there is no password stored here,
# Keycloak owns that (keycloak/ago-chat-realm.json seeds the matching demo-operator/demo-admin users).
#
# `5-08`: also seeds a second demo operator holding the "Admin" role (site:configure,
# site:manage_operators, attachment:delete - authorization.md's admin-role bullet, adr/0016's own
# naming convention) - the console needs a real account with a *different* permission set than
# demo-operator's to manually verify "an admin sees every conversation, an ordinary operator does
# not" and "an admin can delete an attachment an ordinary operator cannot" (5-08's own Done-when).
# The admin demo operator also gets the "Operator" role, not Admin-only - it needs conversation:read/
# send/assign too, to actually be assignable a conversation and exercise the attachment-delete action
# inside its own message thread the same way any operator would (this item's own scoping note: the
# admin's site-wide view is read-only summary data, not a bypass of the existing per-conversation
# assignment/read checks - see 5-08's commit-prep notes for why that bypass was deliberately not
# built). Granting the Operator role's permission *set* to a second role, not adding a third role
# that duplicates it, keeps "which permissions exist" answerable from the `roles` table alone.
#
# Seed-script-only, deliberately: adr/0016 left "who can grant a role" ungranted by anything but this
# script, and 5-08's own scope explicitly defers a role-assignment UI (a general role-editor is out of
# scope per that item's own notes) - this remains the only way any role, Operator or Admin, is ever
# granted in this project today.
set -euo pipefail

NETWORK="ago-chat-infra_default"

: "${POSTGRES_USER:?Set POSTGRES_USER (source docker/.env first)}"
: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD (source docker/.env first)}"
: "${POSTGRES_DB:?Set POSTGRES_DB (source docker/.env first)}"

# Fixed ids, not random ones - the whole point is that re-running this script is a no-op, and a
# fresh uuid every run would defeat that even with ON CONFLICT DO NOTHING. EXTERNAL_SUBJECT_ID must
# match the demo-operator user's own fixed `id` in keycloak/ago-chat-realm.json - that is the only
# link between "a token Keycloak issued for this user" and "this operators row" (5-05, adr/0022).
readonly SITE_ID="00000000-0000-0000-0000-000000000001"
readonly OPERATOR_ID="00000000-0000-0000-0000-000000000002"
readonly ROLE_ID="00000000-0000-0000-0000-000000000003"
readonly EXTERNAL_SUBJECT_ID="00000000-0000-0000-0000-000000000004"
readonly PUBLIC_KEY="demo_site"

# `5-08`: the admin demo operator - EXTERNAL_SUBJECT_ID matches demo-admin's fixed `id` in
# keycloak-realm-import.json, the same link OPERATOR_ID/EXTERNAL_SUBJECT_ID above already establish
# for demo-operator.
readonly ADMIN_OPERATOR_ID="00000000-0000-0000-0000-000000000006"
readonly ADMIN_ROLE_ID="00000000-0000-0000-0000-000000000007"
readonly ADMIN_EXTERNAL_SUBJECT_ID="00000000-0000-0000-0000-000000000005"

# `8-02`: a second, entirely independent site and operator - not a variant of the first, a genuinely
# separate tenant with its own role and its own Keycloak identity, seeded specifically so a live
# demo can show "an operator logged into one tenant cannot see the other's conversations" without
# having to explain it - the two tenants just visibly don't share anything. EXTERNAL_SUBJECT_ID2
# matches demo-operator-2's fixed `id` in keycloak-realm-import.json, same link as above.
readonly SITE2_ID="00000000-0000-0000-0000-000000000008"
readonly OPERATOR2_ID="00000000-0000-0000-0000-000000000009"
readonly ROLE2_ID="00000000-0000-0000-0000-00000000000a"
readonly EXTERNAL_SUBJECT_ID2="00000000-0000-0000-0000-00000000000b"
readonly PUBLIC_KEY2="demo_site2"

SQL=$(cat <<SQL
-- DO UPDATE, not DO NOTHING, for allowed_origins specifically (5-06): an existing local install
-- seeded before ago-console's own dev origin (:5173) was added would otherwise never pick it up on
-- a re-run - the same "re-linking" reasoning 5-05's own operator row update already established.
insert into sites (id, public_key, allowed_origins)
values ('$SITE_ID', '$PUBLIC_KEY', array['http://localhost:8080', 'http://localhost:5173']::text[])
on conflict (id) do update set allowed_origins = excluded.allowed_origins;

insert into operators (id, site_id, status, capacity, external_subject_id)
values ('$OPERATOR_ID', '$SITE_ID', 'Online', 5, '$EXTERNAL_SUBJECT_ID')
on conflict (id) do update set external_subject_id = excluded.external_subject_id;

insert into operators (id, site_id, status, capacity, external_subject_id)
values ('$ADMIN_OPERATOR_ID', '$SITE_ID', 'Online', 5, '$ADMIN_EXTERNAL_SUBJECT_ID')
on conflict (id) do update set external_subject_id = excluded.external_subject_id;

insert into roles (id, site_id, name, permissions)
values ('$ROLE_ID', '$SITE_ID', 'Operator',
        array['conversation:read', 'conversation:send', 'conversation:assign']::text[])
on conflict (id) do nothing;

insert into roles (id, site_id, name, permissions)
values ('$ADMIN_ROLE_ID', '$SITE_ID', 'Admin',
        array['site:configure', 'site:manage_operators', 'attachment:delete']::text[])
on conflict (id) do nothing;

insert into operator_roles (operator_id, role_id)
values ('$OPERATOR_ID', '$ROLE_ID')
on conflict (operator_id, role_id) do nothing;

insert into operator_roles (operator_id, role_id)
values ('$ADMIN_OPERATOR_ID', '$ROLE_ID')
on conflict (operator_id, role_id) do nothing;

insert into operator_roles (operator_id, role_id)
values ('$ADMIN_OPERATOR_ID', '$ADMIN_ROLE_ID')
on conflict (operator_id, role_id) do nothing;

-- `8-02`: the second, independent tenant - its own site, own role, own operator. No row above
-- references any of these ids, and nothing here references any of the ids above; that is the
-- entire point of a second tenant existing.
insert into sites (id, public_key, allowed_origins)
values ('$SITE2_ID', '$PUBLIC_KEY2', array['http://localhost:8080', 'http://localhost:5173']::text[])
on conflict (id) do update set allowed_origins = excluded.allowed_origins;

insert into operators (id, site_id, status, capacity, external_subject_id)
values ('$OPERATOR2_ID', '$SITE2_ID', 'Online', 5, '$EXTERNAL_SUBJECT_ID2')
on conflict (id) do update set external_subject_id = excluded.external_subject_id;

insert into roles (id, site_id, name, permissions)
values ('$ROLE2_ID', '$SITE2_ID', 'Operator',
        array['conversation:read', 'conversation:send', 'conversation:assign']::text[])
on conflict (id) do nothing;

insert into operator_roles (operator_id, role_id)
values ('$OPERATOR2_ID', '$ROLE2_ID')
on conflict (operator_id, role_id) do nothing;
SQL
)

docker run --rm --network "$NETWORK" \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  postgres:17-alpine \
  psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "$SQL"

echo "Demo site ready: public_key=$PUBLIC_KEY"
echo "Demo operator ready: id=$OPERATOR_ID (role: Operator, Keycloak user: demo-operator)"
echo "Demo admin ready: id=$ADMIN_OPERATOR_ID (roles: Operator + Admin, Keycloak user: demo-admin)"
echo "Second demo site ready: public_key=$PUBLIC_KEY2"
echo "Second demo operator ready: id=$OPERATOR2_ID (role: Operator, Keycloak user: demo-operator-2)"
