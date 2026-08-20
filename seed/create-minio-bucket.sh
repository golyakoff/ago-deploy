#!/usr/bin/env bash
# Creates the attachments bucket the demo tenant will upload to (docs/architecture/file-storage.md).
#
# Only the MinIO piece of "seed the demo tenant, an operator, and the MinIO bucket"
# (backlog/0-03-local-infrastructure.md) - Postgres has no schema yet (Stage 1 adds it), so there is
# nothing to seed a tenant or operator row into. That half of this script arrives with Stage 1.
set -euo pipefail

BUCKET="${1:-ago-chat-attachments}"
NETWORK="ago-chat-infra_default"

: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER (source docker/.env first)}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD (source docker/.env first)}"

docker run --rm --network "$NETWORK" \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  --entrypoint /bin/sh \
  minio/mc:latest -c "
    mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" &&
    mc mb --ignore-existing local/$BUCKET
  "

echo "Bucket '$BUCKET' ready."
