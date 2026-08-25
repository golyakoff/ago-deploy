#!/usr/bin/env bash
# Notices when the backup arrangement has quietly stopped working, and mails a person about it.
#
# There are two ways this arrangement fails silently, and they need different watchers:
#
#   1. The node's own timer stops producing artifacts. Detectable here.
#   2. The pull stops running - the author's machine is off for a fortnight, or the scheduled task
#      broke. **This is the one that matters**, because artifacts that never leave the node are not
#      backups at all, and nothing on the author's machine can report its own absence.
#
# Both are checked here, on the node, because the node is the thing that is always on. `backup-pull.sh`
# touches `.last-pull-ok` on the node after every successful pull, which is what makes (2) visible
# from here at all.
#
# Delivery reuses `15-03`/`adr/0045`'s path exactly: the node's own Postfix, to the `alerts@` alias,
# which expands to a real mailbox held in `/etc/aliases` and in no repository. No Prometheus rule, no
# Alertmanager route, no manifest change - this is a systemd timer and `sendmail`.
set -euo pipefail

STAGING="${AGO_BACKUP_DIR:-$HOME/ago/backups}"
TO="${AGO_BACKUP_ALERT_TO:-alerts@reserve-me.ru}"
FROM="${AGO_BACKUP_ALERT_FROM:-no-reply@reserve-me.ru}"
MAX_BACKUP_HOURS="${AGO_BACKUP_MAX_AGE_HOURS:-30}"
MAX_PULL_HOURS="${AGO_BACKUP_MAX_PULL_AGE_HOURS:-72}"

age_hours() { # path -> hours since mtime, or 999999 when absent
  [ -e "$1" ] || { echo 999999; return; }
  echo $(( ( $(date -u +%s) - $(stat -c %Y "$1") ) / 3600 ))
}

problems=""

newest=$(ls -1t "$STAGING"/ago-backup-*.tar.gpg 2>/dev/null | head -1 || true)
if [ -z "$newest" ]; then
  problems="${problems}- No backup artifact exists on the node at all (looked in $STAGING).\n"
else
  h=$(age_hours "$newest")
  [ "$h" -gt "$MAX_BACKUP_HOURS" ] && \
    problems="${problems}- Newest artifact on the node is ${h}h old (threshold ${MAX_BACKUP_HOURS}h): $(basename "$newest")\n"
fi

# The threshold here is deliberately looser than the backup one. A missed pull over a weekend is not
# an incident; three days of missed pulls means the only copies of this deployment's data are on the
# disk that the backup exists to survive.
ph=$(age_hours "$STAGING/.last-pull-ok")
if [ "$ph" -ge 999999 ]; then
  problems="${problems}- No successful pull has ever been recorded (no $STAGING/.last-pull-ok).\n"
elif [ "$ph" -gt "$MAX_PULL_HOURS" ]; then
  problems="${problems}- Last successful pull was ${ph}h ago (threshold ${MAX_PULL_HOURS}h). Artifacts are\n  accumulating on the node and nowhere else - which is not a backup.\n"
fi

[ -z "$problems" ] && exit 0

/usr/sbin/sendmail -t <<EOF
From: AGO backup watchdog <$FROM>
To: $TO
Subject: [AGO] backup is not working

The node's backup watchdog found a problem on $(hostname) at $(date -u --iso-8601=seconds):

$(printf '%b' "$problems")
Staging directory now holds:
$(ls -1t "$STAGING"/ago-backup-*.tar.gpg 2>/dev/null | head -5 | sed 's/^/  /' || echo "  (nothing)")

Runbook: docs/runbooks/backup-and-restore.md in ago-root.
EOF
