#!/usr/bin/env bash
# Put the three Ago.Chat.* hosts - or the two Ago.Calendar.* hosts, or one frontend - back on their
# previous images.
#
#   ./rollback.sh                        undo one revision on all three chat hosts (Kubernetes' own
#                                         history)
#   ./rollback.sh <commit-sha>           go to a specific published build of the three chat hosts
#   ./rollback.sh calendar               undo one revision on both calendar hosts
#   ./rollback.sh calendar <commit-sha>  go to a specific published build of the calendar hosts
#   ./rollback.sh <frontend>             undo one revision on one frontend
#   ./rollback.sh <frontend> <commit-sha> go to a specific published build of that frontend
#   ./rollback.sh --history              show what there is to go back to, and stop
#
# <frontend> is console | demo-shop1 | demo-shop2 | landing | calendar-console (`15-07`, `20-25`). The
# bare `./rollback.sh` still means the three chat hosts and nothing else, deliberately: during an
# incident the no-argument path must stay the one thing with no decision in it.
#
# `20-25`: AGO Calendar deliberately does NOT join the bare, no-argument path, and gets its own named
# scope ("calendar") instead of one shared across both products. **This is the decision this item
# forces, stated with the alternative it replaced:** one `rollback.sh` that rolled back both products
# together was considered and rejected. Rolling back AGO Chat because AGO Calendar broke - or the
# reverse - is a bad trade in both directions: the products run independently, fail independently
# (`ago-calendar` has its own database, its own three-Deployment set, no shared failure domain with
# `ago-chat` beyond the one Postgres instance and the one Keycloak realm), and an incident in one is not
# evidence the other needs touching. Scoping "calendar" the same way a <frontend> is already scoped -
# named explicitly, never implied - keeps the property the bare path exists for: the one-word command
# still has no decision in it, because it still names only the hosts it has always named.
#
# `15-06`/`adr/0047`. This is separate from deploy.sh on purpose. During an incident the thing you
# need is one word with no arguments to get wrong, and the thing you do not need is a script that
# also builds, pulls and migrates. `./rollback.sh` is that word.
#
# **Read this before running it.** Rolling an image back does nothing at all to the database. See
# "Migrations" at the bottom - it is short, and it is the part every rollback story gets wrong. That
# section now covers AGO Calendar too, and says plainly what does NOT hold for it (`8-08`'s coupling,
# in reverse) and why that is a deliberate match to the existing chat behaviour rather than a new gap.
set -euo pipefail

NS="${NS:-ago-chat}"
DOMAIN="${DOMAIN:-reserve-me.ru}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

DEPLOYMENTS=(ago-chat-api ago-chat-worker ago-chat-webhooks)
# `20-25`: the calendar's own two running hosts - see deploy.sh's CALENDAR_HOSTS for why two and not
# three (the migrator is a Job, never a rollout target in either script).
CALENDAR_DEPLOYMENTS=(ago-calendar-api ago-calendar-worker)
# `15-07`: name-as-typed:deployment, the same table deploy.sh keeps. `20-25` adds calendar-console.
FRONTENDS=("console:ago-console" "demo-shop1:ago-demo-shop1" "demo-shop2:ago-demo-shop2" "landing:ago-landing" "calendar-console:ago-calendar-console")

frontend_deployment() {
  local entry
  for entry in "${FRONTENDS[@]}"; do
    [ "${entry%%:*}" = "$1" ] && { echo "${entry##*:}"; return 0; }
  done
  return 1
}

if [ "${1:-}" = "--history" ]; then
  # All nine now, not just the hosts (`15-07`, `20-25`). The point of --history is to show what there
  # *is* to go back to, and the surface with nothing to go back to was the one that needed it: every
  # static bundle's revisions used to read `ago-console:local`, indistinguishable from each other.
  for d in "${DEPLOYMENTS[@]}" "${CALENDAR_DEPLOYMENTS[@]}" "${FRONTENDS[@]##*:}"; do
    step "$d"
    # The images each stored revision would restore, which `rollout history` alone does not show.
    kc get replicaset -n "$NS" -l "app=$d" \
      -o custom-columns='REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,IMAGE:.spec.template.spec.containers[0].image,DESIRED:.spec.replicas' \
      --sort-by='.metadata.annotations.deployment\.kubernetes\.io/revision'
  done
  exit 0
fi

# `15-07`/`20-25`: which Deployments this invocation undoes. "calendar", a named frontend, or the
# three chat hosts. "calendar" is checked before frontend_deployment because it is not a FRONTENDS
# entry - it moves two Deployments, the same shape the bare (no-argument) chat path uses, just under a
# name instead of implicitly.
TARGETS=("${DEPLOYMENTS[@]}")
WHAT="each host"
if [ -n "${1:-}" ] && ! printf '%s' "$1" | grep -qE '^[0-9a-f]{40}$'; then
  if [ "$1" = "calendar" ]; then
    TARGETS=("${CALENDAR_DEPLOYMENTS[@]}")
    WHAT="calendar"
    shift
  elif d="$(frontend_deployment "$1")"; then
    # Not a SHA and not "calendar", so it must name a frontend - a typo has to be an error here, not
    # a silent fallback to rolling the whole backend back, which is the last thing someone who typed
    # "consle" wanted.
    TARGETS=("$d")
    WHAT="$d"
    shift
  else
    echo "unknown component '$1'." >&2
    echo "usage: $0 [console|demo-shop1|demo-shop2|landing|calendar-console|calendar] [<commit-sha>] | $0 --history" >&2
    exit 2
  fi
fi

# A specific build: that is exactly what deploy.sh does, and a second implementation of it would be
# a second thing to keep correct. Rolling "back" to a named tag is the same operation as rolling
# forward to one - only the intent differs, and intent is not a code path.
if [ -n "${1:-}" ]; then
  step "Rolling back to $1"
  if [ "$WHAT" = "each host" ]; then
    exec "$HERE/deploy.sh" "$1"
  elif [ "$WHAT" = "calendar" ]; then
    exec "$HERE/deploy.sh" calendar "$1"
  else
    # deploy.sh takes the name as typed, not the Deployment name; recover it from the table.
    for entry in "${FRONTENDS[@]}"; do
      [ "${entry##*:}" = "$WHAT" ] && exec "$HERE/deploy.sh" "${entry%%:*}" "$1"
    done
  fi
fi

step "Before"
"$HERE/deploy.sh" --current

step "Undoing one revision on ${WHAT}"
# `kubectl rollout undo` uses the Deployment's own revision history (revisionHistoryLimit, 10 by
# default), which survives independently of any registry - so this works even when the reason for
# the rollback is that the registry itself is unreachable. That is why it is the no-argument path.
for d in "${TARGETS[@]}"; do
  kc rollout undo "deployment/$d" -n "$NS"
done

step "Waiting"
for d in "${TARGETS[@]}"; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "After"
"$HERE/deploy.sh" --current

step "Smoke"
CHAT_REPO="${CHAT_REPO:-$HOME/ago/ago-chat}" "$HERE/smoke.sh" "$DOMAIN"

cat <<'EOF'

Two things this did NOT do, both of which are now yours:

  1. The database. Schema only moves forward here. Migrations are additive by policy, so an earlier
     image runs unharmed against a later schema - it ignores columns it does not know about. That is
     a property to keep deliberately: a migration must stay compatible with the image immediately
     before it (expand now, contract in a later release). If the bad release carried a destructive
     migration - a dropped or renamed column, a narrowed type - this rollback is not enough, and the
     recovery is a restore (15-02), not a smaller version of this.

     ONE SUCH BOUNDARY EXISTS TODAY, and this script cannot detect it for you:
     20260901213751_Stage15RepartitionMessagesByTenantHash (15-09/adr/0087) rebuilt `messages` and
     repartitioned it by HASH (site_id). Do not roll ago-chat back to a commit older than that
     migration - the pre-15-09 worker still runs PartitionMaintenanceJob, which would try to add a
     monthly RANGE partition to a table that no longer has a time dimension. Across that boundary the
     recovery is a restore (15-02). Rolling back within the post-15-09 range is unaffected.

     THE CALENDAR (20-25): `ago_calendar` inherits the identical policy and the identical gap -
     Ago.Calendar.Migrator offers no --down either, confirmed against its own Program.cs ("there is
     deliberately no --down and no --target"). It also already has one destructive migration,
     20260901115524_Stage20AddWorkerScheduleAndRemoveCalendarBuffer (20-14), which drops
     calendars.buffer_minutes. That migration is baked into ee3b38a, the very first ago-calendar image
     this cluster has ever run (20-20) - so there is currently no earlier calendar image in this
     cluster's history to roll back to, and `./rollback.sh calendar` with no SHA cannot cross it. Naming
     an explicit SHA older than ee3b38a to `./rollback.sh calendar <sha>` could.

  2. k8s/overlays/demo/kustomization.yaml still names the tag someone last committed - for the chat
     hosts, the calendar hosts and the calendar migrator alike (20-25: the migrator's tag does not move
     with this script, since it is a Job and not a rollout target here; see deploy.sh's own note on
     that). A `kubectl apply -k overlays/demo` would undo this rollback. Update the newTag values this
     rollback moved to whatever './deploy.sh --current' now prints, and commit it - and if this was a
     calendar rollback, update ago-calendar-migrator's own newTag by hand to match, to hold 8-08's
     coupling.
EOF
