#!/usr/bin/env bash
# Creates the attachments bucket the demo tenant will upload to (docs/architecture/file-storage.md).
#
# Only the MinIO piece of "seed the demo tenant, an operator, and the MinIO bucket"
# (backlog/0-03-local-infrastructure.md) - Postgres has no schema yet (Stage 1 adds it), so there is
# nothing to seed a tenant or operator row into. That half of this script arrives with Stage 1.
#
# `23-76`: also sets the bucket's own hard quota - the ceiling item `23-76` names as "a ceiling the
# application cannot exceed even if it is wrong." `minio.yaml`'s own PVC comment already says
# `storage: 2Gi` there is a label, not an enforced limit (`local-path`/`hostpath` applies none); this
# is the thing that actually is enforced, by MinIO itself, independent of anything `Ago.Chat.*` gets
# wrong about its own per-tenant quota (`AttachmentStorageQuotaOptions`, `ago-chat`). `mc quota set`,
# not `mc admin bucket quota set` - the latter is what older `mc` releases used; this pinned image
# (`minio/mc:latest` here, the same `RELEASE.2025-08-13` the bundled client in
# `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` also carries) renamed the subcommand, confirmed
# live against this exact stack: `mc quota set local/attachments --size 5GiB` succeeds and
# `mc admin bucket quota set` does not exist on this version. Idempotent - `mc quota set` replaces
# whatever quota (if any) the bucket already had, so re-running this script after a value change here
# converges the running deployment rather than erroring on "already set."
#
# **5 GiB, a starting point, not measured** (CLAUDE.md: "do not invent numbers... measure or stay
# silent") - this deployment is one node sharing its disk between Postgres, Redis, RabbitMQ and every
# other pod (`minio.yaml`'s own Recreate-strategy comment: "MinIO on this node shares a machine with
# Postgres and Redis; a full disk is not a degraded upload feature, it is an outage of everything").
# 5 GiB is comfortably below what this node's own disk can spare for one feature, while being large
# enough that the free tier's own 100 MiB ceiling (`AttachmentStorageQuotaOptions.FreeTierTotalBytes`)
# and several tenants' worth of the cumulative paid-tier ceiling both fit inside it many times over
# without this bucket-level backstop being the thing a legitimate paying tenant ever actually hits -
# it exists to catch the application being wrong, not to be a second, tighter per-tenant limit.
set -euo pipefail

BUCKET="${1:-attachments}"
BUCKET_QUOTA="${MINIO_ATTACHMENTS_BUCKET_QUOTA:-5GiB}"
NETWORK="ago-chat-infra_default"

: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER (source docker/.env first)}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD (source docker/.env first)}"

docker run --rm --network "$NETWORK" \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  --entrypoint /bin/sh \
  minio/mc:latest -c "
    mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" &&
    mc mb --ignore-existing local/$BUCKET &&
    mc quota set local/$BUCKET --size $BUCKET_QUOTA
  "

echo "Bucket '$BUCKET' ready, hard quota $BUCKET_QUOTA."
