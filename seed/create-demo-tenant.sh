#!/usr/bin/env bash
# Creates the demo site and operator (backlog/0-03-local-infrastructure.md's seed/ note; the schema
# this needs arrived with 1-04). Idempotent - fixed, well-known ids and ON CONFLICT DO NOTHING mean
# running this twice never creates a second demo site.
#
# Neither printed value is a secret: the site's public_key identifies a tenant and grants nothing
# beyond starting a visitor session (api-design.md); the operator id is what 1-06's dev-only
# `POST /dev/operator-session` trades for a session token - there is no password, because the stub
# it feeds is explicitly not a production auth path (adr/0016, authorization.md).
set -euo pipefail

NETWORK="ago-chat-infra_default"

: "${POSTGRES_USER:?Set POSTGRES_USER (source docker/.env first)}"
: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD (source docker/.env first)}"
: "${POSTGRES_DB:?Set POSTGRES_DB (source docker/.env first)}"

# Fixed ids, not random ones - the whole point is that re-running this script is a no-op, and a
# fresh uuid every run would defeat that even with ON CONFLICT DO NOTHING.
readonly SITE_ID="00000000-0000-0000-0000-000000000001"
readonly OPERATOR_ID="00000000-0000-0000-0000-000000000002"
readonly ROLE_ID="00000000-0000-0000-0000-000000000003"
readonly PUBLIC_KEY="demo_site"

SQL=$(cat <<SQL
insert into sites (id, public_key, allowed_origins)
values ('$SITE_ID', '$PUBLIC_KEY', array['http://localhost:8080']::text[])
on conflict (id) do nothing;

insert into operators (id, site_id, status, capacity)
values ('$OPERATOR_ID', '$SITE_ID', 'Online', 5)
on conflict (id) do nothing;

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
echo "Demo operator ready: id=$OPERATOR_ID (role: Operator)"
