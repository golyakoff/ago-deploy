#!/usr/bin/env bash
# Pulls the node's staged backup artifacts onto a machine the node cannot destroy, prunes the local
# copies past the retention window, and refuses quietly to succeed when the newest copy is stale.
#
# **This script is the backup.** Everything `backup.sh` does on the node is preparation: a dump that
# never leaves the host it was dumped from protects against operator and software error only, which
# is real and is not what the failure mode - a dead disk, a suspended account, a compromised root -
# actually needs.
#
# Runs on the author's own machine (`backlog/15-02`'s recorded destination decision, 2026-08-25), over
# the SSH access that already exists. No SFTP daemon, no third-party account, no new inbound port.
#
# Deliberately `ssh` + `scp` rather than `rsync`: Git Bash on Windows ships neither rsync nor a
# package manager to get one, and at this artifact size (tens of megabytes, whole-file, never
# modified after it is written) rsync's delta transfer would save nothing worth a dependency.
set -euo pipefail

# The node address is supplied by the caller and is deliberately not written in this repository
# (CLAUDE.md: no real endpoint in a public repo).
: "${AGO_NODE:?set AGO_NODE to the node address}"
SSH_USER="${AGO_SSH_USER:-ago}"
SSH_KEY="${AGO_SSH_KEY:-$HOME/.ssh/ago-vps-ed25519}"
REMOTE_DIR="${AGO_BACKUP_REMOTE_DIR:-ago/backups}"
LOCAL_DIR="${AGO_BACKUP_LOCAL_DIR:-$HOME/ago-backups}"
KEEP_DAYS="${AGO_BACKUP_KEEP_DAYS:-30}"
STALE_HOURS="${AGO_BACKUP_STALE_HOURS:-30}"

# -n matters and is not decoration: without it the `ssh` call inside the download loop below consumes
# the remaining lines of the loop's own input, and the pull silently fetches only the first artifact.
# Found exactly that way on the first real run.
SSH=(ssh -n -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$AGO_NODE")

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

mkdir -p "$LOCAL_DIR"
chmod 700 "$LOCAL_DIR" 2>/dev/null || true

started_at=$(date -u +%s)
pulled=0

log "listing artifacts on the node"
remote_list=$("${SSH[@]}" "ls -1 $REMOTE_DIR/ago-backup-*.tar.gpg 2>/dev/null" || true)
[ -n "$remote_list" ] || { echo "PULL FAILED: the node has no backup artifacts at all" >&2; exit 1; }

while read -r remote_path; do
  [ -n "$remote_path" ] || continue
  name=$(basename "$remote_path")
  [ -f "$LOCAL_DIR/$name" ] && continue

  log "pulling $name"
  scp -q -i "$SSH_KEY" "$SSH_USER@$AGO_NODE:$remote_path" "$LOCAL_DIR/$name.part"
  # The checksum is computed on the node, over the ciphertext, and compared here. It proves the
  # transfer, not the contents - gpg's own AEAD check is what proves the contents, at decrypt time,
  # which is the only moment anything can meaningfully verify them.
  want=$("${SSH[@]}" "cat $remote_path.sha256" 2>/dev/null || echo "")
  got=$(sha256sum "$LOCAL_DIR/$name.part" | awk '{print $1}')
  if [ -n "$want" ] && [ "$want" != "$got" ]; then
    rm -f "$LOCAL_DIR/$name.part"
    echo "PULL FAILED: checksum mismatch on $name" >&2
    exit 1
  fi
  mv "$LOCAL_DIR/$name.part" "$LOCAL_DIR/$name"
  pulled=$((pulled + 1))
done <<< "$remote_list"

# --- Retention --------------------------------------------------------------------------------
#
# The window that makes "we deleted it" true. `architecture/personal-data.md`'s "Deletion versus
# backups" resolves the contradiction between erasure and restorability by bounding how long a copy
# survives, and copies sitting on a personal disk indefinitely would make that statement false. So the
# local copies expire, on the same window the published policy will state.
log "pruning local copies older than $KEEP_DAYS days"
find "$LOCAL_DIR" -maxdepth 1 -name 'ago-backup-*.tar.gpg' -mtime "+$KEEP_DAYS" -print -delete

# --- Freshness --------------------------------------------------------------------------------
#
# The weak point of this whole arrangement is that it depends on a machine being switched on and a
# scheduled task not having quietly failed, and silence looks exactly like success. Two halves cover
# it: this check, which notices here; and the node-side watchdog, which notices when *this script*
# stops running - because a pull that never happens cannot report itself missing.
newest=$(ls -1t "$LOCAL_DIR"/ago-backup-*.tar.gpg 2>/dev/null | head -1 || true)
if [ -z "$newest" ]; then
  echo "PULL FAILED: no local copies after the pull" >&2
  exit 1
fi
age_h=$(( ( $(date -u +%s) - $(stat -c %Y "$newest") ) / 3600 ))

# Only touched after everything above succeeded. The node's watchdog reads its age, so a pull that
# fails halfway leaves the marker stale and the node mails a person about it.
"${SSH[@]}" "date -u --iso-8601=seconds > $REMOTE_DIR/.last-pull-ok"

elapsed=$(( $(date -u +%s) - started_at ))
log "pulled $pulled new artifact(s) in ${elapsed}s"
log "local copies: $(ls -1 "$LOCAL_DIR"/ago-backup-*.tar.gpg | wc -l), newest $(basename "$newest") (${age_h}h old)"

if [ "$age_h" -gt "$STALE_HOURS" ]; then
  echo "STALE: the newest backup is ${age_h}h old (threshold ${STALE_HOURS}h) - the node's backup timer is not running" >&2
  exit 2
fi
