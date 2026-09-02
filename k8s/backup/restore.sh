#!/usr/bin/env bash
# Restores one pulled backup artifact into a target Postgres and a target S3 endpoint, and prints what
# it put there so the numbers can be compared against the manifest sealed inside the artifact.
#
# **It refuses to run against the live deployment**, by construction: the target is supplied entirely
# through environment variables and there is no default pointing at anything real. A restore is
# performed into a scratch target and verified there; putting data back into production is a separate,
# deliberate act with its own decision to make about what is already in there.
#
# Runs anywhere the private half of the backup key is - which is the author's own machine, and by
# design never the node.
set -euo pipefail

ARTIFACT="${1:-}"
[ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] || {
  echo "usage: restore.sh <ago-backup-*.tar.gpg>" >&2
  echo "  env: PGHOST PGPORT PGUSER PGPASSWORD  (a scratch Postgres, never the live one)" >&2
  echo "       S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY [S3_BUCKET=attachments]" >&2
  echo "       KEYCLOAK_DB_SCRATCH_PASSWORD (what the restored 'keycloak' role's password is reset to)" >&2
  exit 64
}

: "${PGHOST:?}" ; : "${PGUSER:?}" ; : "${PGPASSWORD:?}"
PGPORT="${PGPORT:-5432}"
S3_BUCKET="${S3_BUCKET:-attachments}"
MC_IMAGE="${MC_IMAGE:-minio/mc:latest}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"
KEYCLOAK_DB_SCRATCH_PASSWORD="${KEYCLOAK_DB_SCRATCH_PASSWORD:-}"

started_at=$(date +%s)
log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# The plaintext of every conversation on the deployment lands here for the duration. Same reasoning as
# backup.sh's staging: as short-lived and as narrow as the script can make it.
work="$(mktemp -d "${TMPDIR:-/tmp}/ago-restore.XXXXXXXX")"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# This script is expected to run where the private key is, and that is a Windows machine under Git
# Bash. Two things about that environment are not cosmetic: `docker -v` needs a Windows-shaped host
# path, and MSYS rewrites any argument that looks like a POSIX path - including the container-side
# half of a -v flag and a `psql -f /w/...`. `cygpath` fixes the first, MSYS_NO_PATHCONV the second.
to_host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
command -v cygpath >/dev/null 2>&1 && export MSYS_NO_PATHCONV=1
work_host="$(to_host_path "$work")"

# Containers reach the scratch target over a named docker network rather than --network host, which
# behaves differently on Docker Desktop than on the node. Default matches the drill compose project.
DOCKER_NETWORK="${DOCKER_NETWORK:-ago-restore-drill_default}"

log "decrypting $(basename "$ARTIFACT")"
# No --trust-model here: decryption uses the private key, which is either present or not. If gpg asks
# for a passphrase, that is the passphrase on the backup key and it is correct that a human types it -
# nothing automated in this design ever decrypts.
gpg --decrypt --output - "$ARTIFACT" | tar -C "$work" -xf -

log "manifest:"
sed 's/^/    /' "$work/manifest.txt" | head -20

# Postgres tooling comes from a container rather than the host, because the host running this is a
# Windows machine with Git Bash and no psql. Same image the deployment itself runs.
in_pg() { docker run --rm -i --network "$DOCKER_NETWORK" \
            -e PGPASSWORD -e PGHOST -e PGPORT -e PGUSER \
            -v "$work_host:/w" "$PSQL_IMAGE" "$@"; }
export PGPASSWORD PGHOST PGPORT PGUSER

# --- Roles ------------------------------------------------------------------------------------
# `globals.sql` recreates the `keycloak` role with the password hash it had on the node. Errors from
# roles that already exist are expected on a re-run and are not fatal; a genuine failure shows up
# immediately afterwards when the database restore cannot set an owner.
#
# **The trap this walked into on the first real run, 2026-08-25.** `pg_dumpall --globals-only` also
# emits `ALTER ROLE ago ... PASSWORD '<the node's hash>'`, and `ago` is the role this script is
# connected as. Applying it silently replaces the scratch target's own superuser password with the
# live deployment's - and since the live one is a secret this script deliberately does not have, every
# subsequent connection fails with `password authentication failed` and the target is unusable. The
# fix has to run inside the *same* psql session, because after the ALTER there is no way back in: the
# session that issued it is already authenticated, later ones are not. Hence one file, appended.
log "restoring roles"
{
  cat "$work/globals.sql"
  printf "\nALTER ROLE %s WITH LOGIN PASSWORD '%s';\n" "$PGUSER" "$PGPASSWORD"
} > "$work/globals-with-reset.sql"
in_pg psql -d postgres -f /w/globals-with-reset.sql >/dev/null 2>&1 \
  || log "  (some globals already existed - continuing)"

# Derived from what the archive actually contains, not from a list - the inverse of `backup.sh`'s own
# enumeration and for the same reason. A restore that knows the database names in advance restores
# exactly the databases somebody thought of when writing this file, and leaves any newer one on the
# floor while still reporting success.
dumps="$(find "$work" -maxdepth 1 -name '*.dump' | sort)"
if [ -z "$dumps" ]; then
  log "FATAL: the archive contains no database dumps - nothing to restore"
  exit 1
fi
log "databases in this archive: $(for d in $dumps; do basename "$d" .dump; done | tr '\n' ' ')"

for dump in $dumps; do
  db="$(basename "$dump" .dump)"
  log "creating and restoring $db"
  in_pg psql -d postgres -Atc "select 1 from pg_database where datname='$db'" | grep -q 1 \
    || in_pg psql -d postgres -Atc "create database $db" >/dev/null
  # --no-owner is deliberately NOT passed: the ownership in the dump is part of what is being
  # verified, and the roles were just restored above.
  in_pg pg_restore -d "$db" --clean --if-exists --no-privileges /w/"$db".dump 2>&1 \
    | grep -vE 'does not exist, skipping|^$' | head -20 || true
done

if [ -n "$KEYCLOAK_DB_SCRATCH_PASSWORD" ]; then
  # The restored role carries the live deployment's password hash. Resetting it in the scratch target
  # means the drill never needs the real one, and the scratch Keycloak gets a password that is only
  # ever a scratch password.
  log "resetting the scratch 'keycloak' role password"
  in_pg psql -d postgres -Atc \
    "alter role keycloak with login password '$KEYCLOAK_DB_SCRATCH_PASSWORD'" >/dev/null
fi

# --- Objects ----------------------------------------------------------------------------------
if [ -n "${S3_ENDPOINT:-}" ]; then
  log "restoring MinIO objects into $S3_BUCKET"
  export S3_ACCESS_KEY S3_SECRET_KEY
  docker run --rm --network "$DOCKER_NETWORK" \
    -e S3_ACCESS_KEY -e S3_SECRET_KEY \
    -v "$(to_host_path "$work/minio"):/in" --entrypoint /bin/sh "$MC_IMAGE" -c "
      mc alias set t $S3_ENDPOINT \"\$S3_ACCESS_KEY\" \"\$S3_SECRET_KEY\" >/dev/null
      mc mb --ignore-existing t/$S3_BUCKET >/dev/null
      mc mirror --overwrite --quiet /in t/$S3_BUCKET >/dev/null
      echo \"    objects now in the target bucket: \$(mc ls --recursive t/$S3_BUCKET | wc -l)\"
    "
else
  log "S3_ENDPOINT not set - skipping object restore (database only)"
fi

# --- What landed ------------------------------------------------------------------------------
log "row counts in the restored ago_chat:"
# count(*), not pg_stat_user_tables.n_live_tup: the statistics collector on a freshly restored
# database has not run yet, so n_live_tup would read 0 for every table and the comparison against the
# manifest - which was taken on a warm database - would look like a total data loss.
in_pg psql -d ago_chat -c "
  select 'conversations' t, count(*) from conversations
  union all select 'messages', count(*) from messages
  union all select 'attachments', count(*) from attachments
  union all select 'visitors', count(*) from visitors
  union all select 'sites', count(*) from sites
  union all select 'operators', count(*) from operators
  union all select 'outbox', count(*) from outbox
  order by 1"
in_pg psql -d keycloak -c "select 'keycloak users' t, count(*) from user_entity"

log "restore finished in $(( $(date +%s) - started_at ))s"
echo
echo "Compare the counts above against the manifest's own '# row counts at dump time' block."
echo "The drill in docs/runbooks/backup-and-restore.md goes further: it reads a specific"
echo "conversation, fetches an attachment's bytes and checks a real login."
