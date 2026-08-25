#!/usr/bin/env bash
# Put the three Ago.Chat.* hosts back on their previous images.
#
#   ./rollback.sh                 undo one revision on all three (Kubernetes' own history)
#   ./rollback.sh <commit-sha>    go to a specific published build instead
#   ./rollback.sh --history       show what there is to go back to, and stop
#
# `15-06`/`adr/0047`. This is separate from deploy.sh on purpose. During an incident the thing you
# need is one word with no arguments to get wrong, and the thing you do not need is a script that
# also builds, pulls and migrates. `./rollback.sh` is that word.
#
# **Read this before running it.** Rolling an image back does nothing at all to the database. See
# "Migrations" at the bottom - it is short, and it is the part every rollback story gets wrong.
set -euo pipefail

NS="${NS:-ago-chat}"
DOMAIN="${DOMAIN:-reserve-me.ru}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

DEPLOYMENTS=(ago-chat-api ago-chat-worker ago-chat-webhooks)

if [ "${1:-}" = "--history" ]; then
  for d in "${DEPLOYMENTS[@]}"; do
    step "$d"
    # The images each stored revision would restore, which `rollout history` alone does not show.
    kc get replicaset -n "$NS" -l "app=$d" \
      -o custom-columns='REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,IMAGE:.spec.template.spec.containers[0].image,DESIRED:.spec.replicas' \
      --sort-by='.metadata.annotations.deployment\.kubernetes\.io/revision'
  done
  exit 0
fi

# A specific build: that is exactly what deploy.sh does, and a second implementation of it would be
# a second thing to keep correct. Rolling "back" to a named tag is the same operation as rolling
# forward to one - only the intent differs, and intent is not a code path.
if [ -n "${1:-}" ]; then
  step "Rolling back to $1"
  exec "$HERE/deploy.sh" "$1"
fi

step "Before"
"$HERE/deploy.sh" --current

step "Undoing one revision on each host"
# `kubectl rollout undo` uses the Deployment's own revision history (revisionHistoryLimit, 10 by
# default), which survives independently of any registry - so this works even when the reason for
# the rollback is that the registry itself is unreachable. That is why it is the no-argument path.
for d in "${DEPLOYMENTS[@]}"; do
  kc rollout undo "deployment/$d" -n "$NS"
done

step "Waiting"
for d in "${DEPLOYMENTS[@]}"; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "After"
"$HERE/deploy.sh" --current

step "Smoke"
CHAT_REPO="${CHAT_REPO:-$HOME/ago/ago-chat}" "$HERE/smoke.sh" "$DOMAIN"

cat <<'EOF'

Two things this did NOT do, both of which are now yours:

  1. The database. Schema only moves forward here. Every migration so far has been additive, so an
     earlier image runs unharmed against a later schema - it ignores columns it does not know about.
     That is a property to keep deliberately: a migration must stay compatible with the image
     immediately before it (expand now, contract in a later release). If the bad release carried a
     destructive migration - a dropped or renamed column, a narrowed type - this rollback is not
     enough, and the recovery is a restore (15-02), not a smaller version of this.

  2. k8s/overlays/demo/kustomization.yaml still names the tag someone last committed. A
     `kubectl apply -k overlays/demo` would undo this rollback. Update those three newTag values to
     whatever './deploy.sh --current' now prints, and commit it.
EOF
