#!/usr/bin/env bash
# Installs the two systemd timers on the node. Idempotent; safe to re-run after a `git pull`.
#
# It deliberately does NOT install the recipient public key. That file is the one part of this
# arrangement a session cannot create for the author: whoever holds its private half is the only party
# who can ever read a backup, and generating that keypair is the author's own act. Without it,
# backup.sh refuses to run rather than silently writing something nobody can decrypt.
set -euo pipefail

REPO_DIR="${AGO_REPO_DIR:-$HOME/ago/ago-deploy}"
UNIT_DIR="${AGO_UNIT_DIR:-/etc/systemd/system}"
RECIPIENT="${AGO_BACKUP_RECIPIENT:-$HOME/ago/backup-recipient.pub}"

chmod +x "$REPO_DIR"/k8s/backup/*.sh

for unit in ago-backup.service ago-backup.timer ago-backup-watchdog.service ago-backup-watchdog.timer; do
  sudo cp "$REPO_DIR/k8s/backup/systemd/$unit" "$UNIT_DIR/$unit"
done

sudo systemctl daemon-reload
sudo systemctl enable --now ago-backup.timer ago-backup-watchdog.timer

if [ ! -f "$RECIPIENT" ]; then
  cat >&2 <<EOF

  The timers are installed and enabled, and every run will FAIL until the recipient public key
  exists at:

      $RECIPIENT

  Generate the keypair on the machine that will hold the backups - never on this node - and copy
  only the public half here. docs/runbooks/backup-and-restore.md has the exact commands.

EOF
  exit 1
fi

systemctl list-timers ago-backup.timer ago-backup-watchdog.timer --no-pager
