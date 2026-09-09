#!/usr/bin/env bash
# `25-14`: restricts the presigned attachment GET's CORS behaviour to the origins `sites.
# allowed_origins` currently permits, mirroring - as closely as MinIO's own CORS model allows, see
# below - the boundary `SiteOriginCorsPolicyProvider` (`ago-chat/src/Ago.Chat.Api/Cors/
# SiteOriginCorsPolicyProvider.cs`) already enforces for the REST API.
#
# **Why server-wide, not per-bucket.** `mc cors set/get/remove` exists in the `mc` CLI and implies
# AWS S3's real per-bucket `PutBucketCors` API is available here. It is not: verified live against
# this exact pinned image (`docker/docker-compose.yml`'s own `minio/minio:RELEASE.2025-09-
# 07T16-13-09Z`) - `mc cors set` fails with "A header you provided implies functionality that is
# not implemented", and `mc admin trace` shows why: the underlying `s3.PutBucketCors` call answers
# `501 Not Implemented` on the wire. The only CORS knob this MinIO version actually enforces is the
# server-wide admin setting `api.cors_allow_origin` (`MINIO_API_CORS_ALLOW_ORIGIN` as an env var,
# equivalently) - one list, for every bucket the server holds. That happens to be fine here since
# this deployment has exactly one bucket (`attachments`), but it is not a bucket-scoped mechanism,
# and nothing about it is MinIO-specific plumbing this script works around - it is the entire
# feature surface.
#
# **Why this is a snapshot, not a subscription, and why that is accepted rather than hidden.**
# `sites.allowed_origins` changes whenever a tenant edits their own site's settings.
# `SiteOriginCorsPolicyProvider` reads it live, per request, which is exactly why the API's own CORS
# layer can react to a change immediately. A storage server's CORS config cannot: it is a static
# value that only changes when something calls `mc admin config set` (this script) and the server
# reloads it. There is no live per-request callout to Postgres or anywhere else, structurally,
# regardless of which S3-compatible product is asked - re-run this script after any tenant changes
# their own allowed origins, or a newly-added origin's presigned GETs will keep failing silently
# (`archive.ts`'s own graceful degradation, `docs/architecture/file-storage.md`) until it does.
#
# **Why not the wildcard `*` MinIO already ships with.** `api.cors_allow_origin` defaults to `*` -
# MinIO's own out-of-the-box CORS posture is wide open, not closed, the opposite of the AWS S3
# default this item's own background section assumed. A wildcard would need no re-syncing and would
# already be "live" today with zero further change, but it cannot be proven to refuse a disallowed
# origin - this item's own Done-when requires exactly that control - and it grants any origin able
# to obtain a presigned URL the ability to read the bytes it points at, not only the tenant the
# attachment belongs to. The explicit, queried-from-`sites` list below is the answer that actually
# satisfies the Done-when, at the stated cost above.
set -euo pipefail

NETWORK="ago-chat-infra_default"

: "${POSTGRES_USER:?Set POSTGRES_USER (source docker/.env first)}"
: "${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD (source docker/.env first)}"
: "${POSTGRES_DB:?Set POSTGRES_DB (source docker/.env first)}"
: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER (source docker/.env first)}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD (source docker/.env first)}"

# Every origin any site currently allows, deduplicated - the same rows CheckCorsOriginHandler
# (ago-chat) reads per request, read once here instead.
ORIGINS="$(docker run --rm --network "$NETWORK" \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  postgres:17-alpine \
  psql -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -t -A \
  -c "select string_agg(distinct origin, ',') from sites, unnest(allowed_origins) as origin;")"
ORIGINS="$(echo "$ORIGINS" | tr -d '[:space:]')"

if [ -z "$ORIGINS" ]; then
  echo "No sites.allowed_origins rows found - nothing to restrict CORS to." >&2
  echo "Run create-demo-tenant.sh (or seed a real site) first." >&2
  exit 1
fi

echo "Restricting MinIO's CORS to: $ORIGINS"

docker run --rm --network "$NETWORK" \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  --entrypoint /bin/sh \
  minio/mc:latest -c "
    mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" &&
    mc admin config set local api cors_allow_origin=\"$ORIGINS\"
  "

# `mc admin service restart` needs an interactive TTY this script never has - confirmed live, it
# fails with "could not open a new TTY: open /dev/tty" - and the new value only takes effect once
# MinIO reloads its config. A plain container restart is what actually applies it (the setting is
# persisted to MinIO's own backend store, not the container's environment, so it survives the
# restart the same way it would survive a pod restart in the cluster loop - verified live, not
# assumed).
MINIO_CONTAINER="$(docker ps --filter "label=com.docker.compose.project=ago-chat-infra" \
  --filter "label=com.docker.compose.service=minio" --format '{{.ID}}')"
if [ -z "$MINIO_CONTAINER" ]; then
  echo "Applied the setting, but could not find the running minio container to restart it." >&2
  echo "Restart it yourself (docker compose restart minio) for the change to take effect." >&2
  exit 1
fi
docker restart "$MINIO_CONTAINER" >/dev/null

echo "MinIO's CORS is now restricted to sites.allowed_origins, and the change is live."
