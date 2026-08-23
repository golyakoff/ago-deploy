#!/usr/bin/env bash
# Creates the demo site and operator (backlog/0-03-local-infrastructure.md's seed/ note; the schema
# this needs arrived with 1-04). Idempotent - fixed, well-known ids and ON CONFLICT DO NOTHING mean
# running this twice never creates a second demo site.
#
# Neither printed value is a secret: the site's public_key identifies a tenant and grants nothing
# beyond starting a visitor session (api-design.md); the operator id resolves from Keycloak's own
# token via OperatorIdentityClaimsTransformation (5-05, adr/0022) - there is no password stored here,
# Keycloak owns that (keycloak/ago-chat-realm.json seeds the matching demo-operator user).
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

insert into roles (id, site_id, name, permissions)
values ('$ROLE_ID', '$SITE_ID', 'Operator',
        array['conversation:read', 'conversation:send', 'conversation:assign']::text[])
on conflict (id) do nothing;

insert into operator_roles (operator_id, role_id)
values ('$OPERATOR_ID', '$ROLE_ID')
on conflict (operator_id, role_id) do nothing;
SQL
)

docker run --rm --network "$NETWORK" \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  postgres:17-alpine \
  psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "$SQL"

echo "Demo site ready: public_key=$PUBLIC_KEY"
echo "Demo operator ready: id=$OPERATOR_ID (role: Operator, Keycloak user: demo-operator)"
