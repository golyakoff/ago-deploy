#!/usr/bin/env bash
# `ago-root/docs/backlog/22-32-the-two-databases-agree-about-who-exists.md`;
# `ago-root/docs/runbooks/tenancy-reconciliation.md` is the runbook this script belongs to - read that
# first, especially before interpreting a non-empty report.
#
# Reads `ago_chat` and `ago_calendar` directly - two separate Postgres databases (not schemas: a plain
# `select ... join ...` cannot span them) - and reports where they disagree about which calendar
# tenants belong to which chat accounts:
#
#   1. an account with an active calendar registration (`enabled_modules`, module_key='calendar',
#      not revoked) but no matching row in the calendar's own `tenants` table - half-failed
#      provisioning: money taken, no calendar ("22-07"'s own words, quoted in `22-32`).
#   2. a chat-originated calendar tenant (`tenants.auto_provisioned = true`) with no active chat
#      account naming it - the shape a revoke leaves behind, since `22-30` made revoke a stamp
#      (`enabled_modules.revoked_at`) rather than a delete, and the calendar side's own revoke handler
#      (`RevokeChatModuleRegistrationHandler`) deletes only its own registration row, never `tenants`,
#      `customers`, `events` or `workers`.
#
# A tenant with `auto_provisioned = false` was registered by a human, not by a chat purchase
# (`RegisterChatModuleHandler`'s own remarks - `Tenant.AutoProvisioned` exists specifically to tell the
# two kinds apart), so it never had a chat account to agree with in the first place. Reported
# separately, as context, never folded into the drift count - a script that counted every standalone
# tenant as "drift" on its very first run would teach its reader to stop trusting it.
#
# There is no `site_id`/`account_id` column on `tenants` linking it back to chat - by construction
# (`adr/0093`, `22-03`), `tenants.id` IS the chat-side `sites.id` for every chat-provisioned tenant.
# That equality is the entire join; get it wrong and every count below is meaningless.
#
# ONLY COUNTS AND IDENTIFIERS - an id and a human-readable name, never a full row, never a credential,
# never anything else `enabled_modules`/`tenants` holds. `22-32`'s own Scope section is why: this is a
# cross-tenant read, and identifiers-only is what keeps it from being a third copy of anyone's data
# (and is why it carries no `adr/0113` access_records entry - it reaches no person's data to record a
# reach of).
#
# REPORTS ONLY. NEVER REPAIRS. `22-32`'s own Out-of-scope section: a reconciliation that auto-fixes
# drift is a program that deletes a tenant's data on the strength of a join, and the first time it is
# wrong it is catastrophically wrong. A non-zero result here is a person's decision, made in
# `ago-root/docs/runbooks/module-grant-and-revoke.md` if a repair is warranted - never this script's.
#
# MANUAL, ON DEMAND - deliberately not a Kubernetes CronJob and not a systemd timer. `22-32`'s own Open
# questions section treats "a scheduled workload holding credentials to two databases" as a decision
# the author has not made, and reserves it explicitly: "not the author's question unless the answer is
# [CronJob]". This script is the other branch - a person runs it, when they want the answer to "is it
# drifting right now?" - same shape `update-landing-prices-from-db.sh` (ago-chat/tools) already uses
# for a single-database on-demand read.
#
# Nothing secure is hardcoded. Both connection strings are whatever `psql` itself accepts - a libpq
# keyword string, a `postgresql://` URI - passed as this script's own first two arguments. Never
# logged, never echoed. As of `20-20`, both databases live on the same Postgres instance under the
# same `ago` role (`ago-deploy/k8s/base/api.yaml`, `calendar-api.yaml` - `AGO_CHAT_CONNECTION_STRING`
# and `AGO_CALENDAR_CONNECTION_STRING` differ only in `Database=`), so today the two arguments are
# usually identical apart from `dbname=`/`Database=` - but this script takes two full strings rather
# than one string plus a second database name, because that coincidence is not a guarantee and nothing
# here should quietly stop working the day it stops holding.
set -euo pipefail

CHAT_CONNECTION="${1:-}"
CALENDAR_CONNECTION="${2:-}"

if [ -z "$CHAT_CONNECTION" ] || [ -z "$CALENDAR_CONNECTION" ]; then
  echo "usage: tenancy-reconciliation-report.sh <ago_chat connection> <ago_calendar connection>" >&2
  echo "  each is whatever psql itself accepts - a libpq keyword string or a postgresql:// URI." >&2
  echo "  see ago-root/docs/runbooks/tenancy-reconciliation.md" >&2
  exit 2
fi

# Best-effort only: reuses `15-03`'s own alert path (Postfix on the node, no auth, no TLS, the
# `alerts` alias in /etc/aliases - `ago-root/docs/runbooks/alerting.md`) exactly the way
# `backup-watchdog.sh` already does, so that a non-zero result reaches the same inbox every other
# alert in this deployment does, on the occasions someone does run this by hand rather than only
# printing to whatever terminal happens to be watching. It does NOT make this a scheduled check - it
# still only fires when a person runs this script - and it never fails the report itself: off the
# node, or on a machine with no `sendmail`, this is silently skipped rather than treated as an error.
MAIL_ON_DRIFT="${TENANCY_REPORT_MAIL_ON_DRIFT:-0}"
ALERT_TO="${TENANCY_REPORT_ALERT_TO:-alerts@reserve-me.ru}"
ALERT_FROM="${TENANCY_REPORT_ALERT_FROM:-no-reply@reserve-me.ru}"

run_query() { # connection query -> pipe-delimited rows, blank lines stripped
  psql "$1" -X -q -t -A -F'|' -c "$2" | grep -v '^[[:space:]]*$' || true
}

# `printf '%s\n' "$var"` always emits one line even for an empty string, which would hand `comm`/`grep`
# a spurious blank "row" the moment either side is genuinely empty (e.g. the very first run, before any
# calendar module has ever been granted). This emits zero lines for an empty string instead.
as_stream() {
  [ -n "$1" ] && printf '%s\n' "$1" || true
}

# `id_lines rows` -> just column 1, sorted, deduplicated. Used to compute the set difference; the full
# rows (name and all) are looked back up afterwards, only for the ids that actually differ.
ids_of() {
  as_stream "$1" | cut -d'|' -f1 | sort -u | grep -v '^[[:space:]]*$' || true
}

# `full_rows ids` -> the rows from full_rows whose id (column 1) appears in ids, one per line. `join`
# rather than a grep pattern built from the ids - a grep alternation built by appending "|" as a field
# anchor is not literal in ERE, it is alternation, and would have matched every row instead of exactly
# one. `join` needs both inputs sorted on the join field, which both already are: `ids` comes out of
# `comm` (sorted, since its own inputs are sorted) and `full_rows` comes straight from a `order by id`
# query.
rows_matching() {
  local full="$1" ids="$2"
  [ -n "$ids" ] || return 0
  join -t'|' -j1 <(as_stream "$ids") <(as_stream "$full")
}

count_lines() { # 0 for an empty string, otherwise the line count - wc -l always exits 0, unlike
                 # `grep -c`, which exits 1 on a zero count and would trip `set -e` here.
  [ -n "$1" ] || { echo 0; return; }
  as_stream "$1" | wc -l | tr -d '[:space:]'
}

echo "reading ago_chat (enabled_modules, calendar module, not revoked)..." >&2
CHAT_ROWS="$(run_query "$CHAT_CONNECTION" "
  select em.site_id, s.name
  from enabled_modules em
  join sites s on s.id = em.site_id
  where em.module_key = 'calendar' and em.revoked_at is null
  order by em.site_id;
")"

echo "reading ago_calendar (tenants)..." >&2
CAL_ROWS="$(run_query "$CALENDAR_CONNECTION" "
  select id, name, auto_provisioned
  from tenants
  order by id;
")"

CHAT_IDS="$(ids_of "$CHAT_ROWS")"
CAL_ALL_IDS="$(ids_of "$CAL_ROWS")"

# Asymmetry 2 is scoped to chat-originated tenants only (auto_provisioned = true). A tenant a human
# registered directly never had a chat account to name it in the first place - see the header comment.
CAL_AUTO_ROWS="$(as_stream "$CAL_ROWS" | awk -F'|' '$3=="t"')"
CAL_AUTO_IDS="$(ids_of "$CAL_AUTO_ROWS")"
STANDALONE_COUNT="$(( $(count_lines "$CAL_ALL_IDS") - $(count_lines "$CAL_AUTO_IDS") ))"

ORPHAN_ACCOUNT_IDS="$(comm -23 <(as_stream "$CHAT_IDS") <(as_stream "$CAL_ALL_IDS") 2>/dev/null || true)"
ORPHAN_TENANT_IDS="$(comm -13 <(as_stream "$CHAT_IDS") <(as_stream "$CAL_AUTO_IDS") 2>/dev/null || true)"

ORPHAN_ACCOUNTS="$(rows_matching "$CHAT_ROWS" "$ORPHAN_ACCOUNT_IDS")"
ORPHAN_TENANTS="$(rows_matching "$CAL_AUTO_ROWS" "$ORPHAN_TENANT_IDS")"

ORPHAN_ACCOUNT_COUNT="$(count_lines "$ORPHAN_ACCOUNTS")"
ORPHAN_TENANT_COUNT="$(count_lines "$ORPHAN_TENANTS")"
CHAT_COUNT="$(count_lines "$CHAT_ROWS")"
CAL_COUNT="$(count_lines "$CAL_ROWS")"
CAL_AUTO_COUNT="$(count_lines "$CAL_AUTO_ROWS")"

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DRIFT_TOTAL="$(( ORPHAN_ACCOUNT_COUNT + ORPHAN_TENANT_COUNT ))"

render_report() {
  echo "tenancy reconciliation report - $STAMP"
  echo
  echo "accounts with an active calendar registration (ago_chat.enabled_modules): $CHAT_COUNT"
  echo "calendar tenants total (ago_calendar.tenants): $CAL_COUNT"
  echo "  of which chat-originated (auto_provisioned = true): $CAL_AUTO_COUNT"
  echo "  of which standalone, never chat-linked (auto_provisioned = false): $STANDALONE_COUNT"
  echo
  echo "== asymmetry 1: accounts with a calendar registration and no matching tenant =="
  echo "count: $ORPHAN_ACCOUNT_COUNT"
  if [ "$ORPHAN_ACCOUNT_COUNT" -eq 0 ]; then
    echo "none"
  else
    printf '%s\n' "$ORPHAN_ACCOUNTS" | while IFS='|' read -r id name; do
      echo "  site_id=$id  name=\"$name\""
    done
  fi
  echo
  echo "== asymmetry 2: chat-originated calendar tenants with no active account naming them =="
  echo "count: $ORPHAN_TENANT_COUNT"
  if [ "$ORPHAN_TENANT_COUNT" -eq 0 ]; then
    echo "none"
  else
    printf '%s\n' "$ORPHAN_TENANTS" | while IFS='|' read -r id name autop; do
      echo "  tenant_id=$id  name=\"$name\""
    done
  fi
  echo
  if [ "$DRIFT_TOTAL" -eq 0 ]; then
    echo "RESULT: no drift - the two databases agree about who exists."
  else
    echo "RESULT: drift found - $DRIFT_TOTAL row(s) need a person's decision (see the runbook). This script only reports; it repairs nothing."
  fi
}

REPORT="$(render_report)"
printf '%s\n' "$REPORT"

if [ "$DRIFT_TOTAL" -gt 0 ] && [ "$MAIL_ON_DRIFT" = "1" ]; then
  if command -v /usr/sbin/sendmail >/dev/null 2>&1; then
    /usr/sbin/sendmail -t <<EOF
From: AGO tenancy reconciliation <$ALERT_FROM>
To: $ALERT_TO
Subject: [AGO] tenancy reconciliation found drift ($DRIFT_TOTAL)

$REPORT

Runbook: ago-root/docs/runbooks/tenancy-reconciliation.md
EOF
  else
    echo "note: TENANCY_REPORT_MAIL_ON_DRIFT=1 but no /usr/sbin/sendmail here - not mailed." >&2
  fi
fi
