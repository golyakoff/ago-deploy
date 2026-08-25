#!/usr/bin/env bash
# Takes one backup of everything on this node that cannot be rebuilt from a manifest, encrypts it to a
# public key this node does not hold the private half of, and leaves it in a staging directory for
# `backup-pull.sh` to fetch from somewhere else.
#
# `backlog/15-02`, `adr/0050`. Read the ADR before changing what goes in or comes out - what is
# deliberately *not* backed up here (Redis, RabbitMQ) is a decision with reasoning, not an omission.
#
# **The file this writes is not the backup.** It is staging. The backup is the copy that lives on a
# machine this node cannot destroy, and that copy is `backup-pull.sh`'s job. A node that dies takes
# every artifact in the staging directory with it.
#
# Runs on the node, as the `ago` user, from a systemd timer (systemd/ago-backup.timer). Everything it
# needs is already installed: k3s's bundled kubectl, gpg, tar and docker (for the MinIO client).
set -euo pipefail

NAMESPACE="${AGO_BACKUP_NAMESPACE:-ago-chat}"
STAGING="${AGO_BACKUP_DIR:-$HOME/ago/backups}"
RECIPIENT="${AGO_BACKUP_RECIPIENT:-$HOME/ago/backup-recipient.pub}"
KEEP="${AGO_BACKUP_KEEP:-7}"
ENV_FILE="${AGO_BACKUP_ENV_FILE:-$HOME/ago/ago-deploy/k8s/overlays/demo/.env}"
MC_IMAGE="${AGO_BACKUP_MC_IMAGE:-minio/mc:latest}"
BUCKET="${AGO_BACKUP_BUCKET:-attachments}"
KUBECTL="${AGO_BACKUP_KUBECTL:-sudo k3s kubectl}"

started_at=$(date -u +%s)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
artifact="$STAGING/ago-backup-$stamp.tar.gpg"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf 'backup FAILED: %s\n' "$*" >&2; exit 1; }

[ -f "$RECIPIENT" ] || fail "no recipient public key at $RECIPIENT - see docs/runbooks/backup-and-restore.md"

mkdir -p "$STAGING"
chmod 700 "$STAGING"

# Plaintext dumps land here and nowhere else. 0700 under the invoking user, removed on every exit path
# including a failure. This is not a new exposure - the live database sits on the same disk in the
# same plaintext - but it is a window, so it is kept as short as the script can make it.
work="$(mktemp -d "${TMPDIR:-/tmp}/ago-backup.XXXXXXXX")"
chmod 700 "$work"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- Postgres ---------------------------------------------------------------------------------
#
# A logical dump (`pg_dump`), not a filesystem or WAL-based copy. At this size - tens of megabytes -
# a logical dump costs seconds, is readable by any Postgres of the same or a newer major version, and
# needs no coordination with the running server. A physical basebackup would be faster to restore and
# would support point-in-time recovery, and `backlog/15-02` puts PITR explicitly out of scope for a
# one-node deployment (`adr/0026`).
#
# **The consistency guarantee, stated exactly.** Each `pg_dump` runs in one repeatable-read snapshot,
# so each *database* is internally consistent to a single instant. There is no snapshot shared
# *between* the two databases: `ago_chat` and `keycloak` are dumped one after the other, seconds
# apart. The one place that matters is `operators.external_subject_id`, which points at a Keycloak
# user id across the boundary - an account created in that window can restore as an operator row
# whose Keycloak user is missing, or the reverse. Both are repairable by hand and neither is silent
# (`/api/v1/operators/me` fails loudly). Fixing it properly would need both databases dumped from one
# transaction, which Postgres cannot do across databases at all.
log "dumping postgres roles (globals)"
# `--globals-only` carries role definitions *including password hashes* - the `keycloak` role's among
# them. It is why this artifact is encrypted rather than merely private, and why a restore into a
# scratch target must reset that password rather than reuse it.
$KUBECTL exec -n "$NAMESPACE" deploy/postgres -- \
  sh -c 'pg_dumpall -U "$POSTGRES_USER" --globals-only' > "$work/globals.sql"

for db in ago_chat keycloak; do
  log "dumping database $db"
  # -Fc: custom format, compressed, restorable selectively with pg_restore. `messages` is
  # PARTITION BY RANGE (adr/0019, adr/0031) - pg_dump handles that natively, emitting the parent, each
  # partition and the ATTACH statements, so no partition-aware special casing is needed here. Verified
  # rather than assumed: the restore drill in docs/runbooks/backup-and-restore.md counts rows per
  # partition after restoring.
  $KUBECTL exec -n "$NAMESPACE" deploy/postgres -- \
    sh -c "pg_dump -U \"\$POSTGRES_USER\" -Fc -d $db" > "$work/$db.dump"
done

# --- MinIO ------------------------------------------------------------------------------------
#
# Object-level (`mc mirror`), not a copy of the PVC directory. A directory copy would be faster and
# would need no client, but it bakes in MinIO's on-disk layout: restoring it requires the same MinIO
# release, and it can never be handed to a hosted S3 if this deployment ever grows one. The object
# form restores into any S3-compatible target, which is the same reasoning `file-storage.md` used to
# put the bytes behind an S3 API in the first place.
#
# Attachment objects are write-once - nothing in `ago-chat` ever rewrites one - so mirroring a live
# store cannot catch a half-written object. An upload in flight is simply absent, exactly as it would
# be if the backup had run a second earlier.
log "mirroring MinIO bucket $BUCKET"
mkdir -p "$work/minio"
minio_secret=$($KUBECTL get deploy minio -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].secretRef.name}')
minio_ip=$($KUBECTL get svc minio -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
MINIO_ROOT_USER=$($KUBECTL get secret "$minio_secret" -n "$NAMESPACE" -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)
MINIO_ROOT_PASSWORD=$($KUBECTL get secret "$minio_secret" -n "$NAMESPACE" -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
# --network host so the container reaches the Service ClusterIP through the node's own kube-proxy
# rules; the credentials arrive as environment variables so they never appear in argv.
sudo -E docker run --rm --network host \
  -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \
  -v "$work/minio:/out" --entrypoint /bin/sh "$MC_IMAGE" -c "
    mc alias set n http://$minio_ip:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null
    mc mirror --overwrite --quiet n/$BUCKET /out >/dev/null
  "
# The container writes as root; the tar below runs as this user.
sudo chown -R "$(id -u):$(id -g)" "$work/minio"

# --- The overlay's .env -----------------------------------------------------------------------
#
# Every credential this deployment uses, in one gitignored file. Included deliberately, and it is the
# one inclusion with a real cost: a leaked artifact stops being only a data breach and becomes a live
# credential breach as well. It is included anyway because a restore without it does not actually
# work under pressure - AUTH_JWT_SIGNING_KEY regenerating invalidates every outstanding visitor token,
# and KEYCLOAK_DB_PASSWORD must match the password hash the restored `keycloak` role carries or
# Keycloak will not start. `adr/0050` records the tradeoff; the standing consequence is that a restore
# performed because an artifact may have been exposed is followed by a credential rotation (`17-03`).
if [ -f "$ENV_FILE" ]; then
  log "including the overlay .env"
  cp "$ENV_FILE" "$work/overlay.env"
else
  log "WARNING: no .env at $ENV_FILE - the artifact will not carry the deployment's credentials"
fi

# --- Manifest ---------------------------------------------------------------------------------
#
# Sealed inside the artifact rather than written beside it, so it describes the bytes it travels with.
# The row counts are what the restore drill compares against - a restore that produces a smaller
# number than this file records is a failed restore, and without this the comparison is a memory.
log "writing manifest"
{
  echo "taken_at_utc=$(date -u --iso-8601=seconds)"
  echo "node_hostname=$(hostname)"
  echo "namespace=$NAMESPACE"
  echo "postgres_version=$($KUBECTL exec -n "$NAMESPACE" deploy/postgres -- \
    sh -c 'psql -U "$POSTGRES_USER" -d postgres -Atc "show server_version"')"
  echo "minio_image=$($KUBECTL get deploy minio -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "keycloak_image=$($KUBECTL get deploy keycloak -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "ago_deploy_rev=$(git -C "$(dirname "$ENV_FILE")" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "minio_object_count=$(find "$work/minio" -type f | wc -l)"
  echo "# --- row counts at dump time ---"
  # -F= rather than building `name=count` in SQL: a string literal inside a double-quoted -c inside a
  # single-quoted sh -c inside kubectl exec is three levels of quoting deep, and it was wrong the first
  # time it ran. Letting psql do the formatting removes the level that broke.
  $KUBECTL exec -n "$NAMESPACE" deploy/postgres -- \
    sh -c 'psql -U "$POSTGRES_USER" -d ago_chat -At -F= -c "select relname, n_live_tup from pg_stat_user_tables order by relname"' \
    | sed 's/^/ago_chat./'
  echo "keycloak.user_entity=$($KUBECTL exec -n "$NAMESPACE" deploy/postgres -- \
    sh -c 'psql -U "$POSTGRES_USER" -d keycloak -Atc "select count(*) from user_entity"')"
  echo "# --- sha256 of the members of this artifact ---"
  (cd "$work" && find . -type f ! -name manifest.txt -print0 | sort -z | xargs -0 sha256sum)
} > "$work/manifest.txt"

# --- Seal -------------------------------------------------------------------------------------
#
# Public-key encryption, to a key whose private half is on the author's machine and has never been on
# this node. Two properties follow, and both are the point: an attacker who owns this node can read
# the live database but cannot read the backup history, and nothing automated anywhere ever needs to
# decrypt - only a human performing a restore does. That is what makes it free to put a passphrase on
# the private key.
log "encrypting to $(basename "$RECIPIENT")"
tar -C "$work" -cf - . \
  | gpg --batch --yes --no-tty --trust-model always \
        --recipient-file "$RECIPIENT" --encrypt --output "$artifact"
chmod 600 "$artifact"

# A plaintext checksum beside the ciphertext, so `backup-pull.sh` can verify a transfer without
# holding the private key. It authenticates the transfer, not the contents - gpg's own integrity
# check does that at decrypt time.
sha256sum "$artifact" | awk '{print $1}' > "$artifact.sha256"

# --- Prune ------------------------------------------------------------------------------------
#
# By count, not by age: the staging directory's job is to hold enough runs for the next pull to catch
# up after a few missed days, and a count is the bound that does not depend on the timer having run.
# The retention window that matters for privacy is enforced on the pulled copies (`backup-pull.sh`).
ls -1t "$STAGING"/ago-backup-*.tar.gpg 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  log "pruning $(basename "$old")"
  rm -f "$old" "$old.sha256"
done

date -u --iso-8601=seconds > "$STAGING/.last-backup-ok"

elapsed=$(( $(date -u +%s) - started_at ))
log "done in ${elapsed}s: $(basename "$artifact") ($(du -h "$artifact" | cut -f1))"
