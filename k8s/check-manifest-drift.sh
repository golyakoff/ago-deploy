#!/usr/bin/env bash
# `15-21`: say out loud when the manifest and the cluster disagree about anything `kubectl set image`
# does not touch.
#
# `redeploy.sh` and `deploy.sh` both move workloads onto a new commit with `kubectl set image` alone -
# see `docs/runbooks/redeploy.md`'s "What it does not apply: manifests" for why that is deliberate
# rather than an oversight. Deliberate or not, it means a change to a Deployment's env, probe,
# resources, replica count, or a NetworkPolicy's spec - committed to this repository - reaches the
# cluster **only** through `apply-demo.sh` (or a bare `kubectl apply -k`), and until now nothing said
# so at the moment it mattered.
#
# `23-45` is the incident this exists for: the configuration `Ago.Chat.Api`'s new startup validation
# needed was correct in `overlays/demo/kustomization.yaml` and absent from the cluster. The next
# `redeploy.sh` moved the image forward and crash-looped the API. Nothing was down only because the
# old ReplicaSet kept serving - luck of ordering, not design. Reproduced without touching a cluster,
# for the record this script exists to leave: `overlays/demo/kustomization.yaml` at `76cb069` (this
# item's base) carries no `Ago.Chat.Api:Site:PublishedName`-shaped guard of its own to replay, so the
# demonstration in this item's commit-prep block instead adds and then reverts one `env:` entry on
# `worker.yaml` to stand in for it - the shape (an env value present in the file, absent from the
# cluster) is identical to `23-45`'s.
#
# WHAT THIS COMPARES. Deployments and NetworkPolicies in the named overlay, against the same objects
# in the live cluster, using `kubectl diff` - not a hand-rolled structural comparison. `kubectl diff`
# already solves the false-positive hazard a bespoke comparison would reintroduce: its three-way merge
# is computed against `kubectl.kubernetes.io/last-applied-configuration`, so a field the API server
# defaults on its own (`creationTimestamp`, `status`, a defaulted `resources` value neither the
# manifest nor `last-applied` ever named) never appears as a difference - it did not appear in the
# earlier `kubectl apply` either, so there is nothing for the three-way merge to reconcile.
#
# WHAT IT DELIBERATELY IGNORES, AND WHY.
#   - **Container image tags.** `redeploy.sh` and `deploy.sh` already print the tags they moved and
#     ask the operator to commit them (`docs/runbooks/redeploy.md`'s "Keep the manifest honest" note);
#     `apply-demo.sh` already refuses an apply that would roll a running image backward (`22-24`).
#     Repeating that check here would only ever fire on the routine, expected gap between "images
#     moved imperatively" and "the file that names them got committed" - the false positive the item
#     this script closes explicitly warns against manufacturing. So every image this overlay pins is
#     rewritten, before the diff runs, to whatever tag the same repository is running *right now* -
#     turning an expected, already-handled difference into no difference at all, and leaving every
#     other field free to be compared honestly.
#   - **Jobs** (the two migrators). `8-08` ties their tags to their hosts', so between an image move
#     and the operator committing it they legitimately differ from the file - and a Job's
#     `spec.template` is immutable, so a dry-run apply against one with a different image does not
#     report a difference, it **errors** (`apply-demo.sh`'s own header has the detail, discovered
#     running `kubectl diff -k` directly). Left out of the comparison entirely, the same reasoning
#     `apply-demo.sh`'s own rollback guard used to leave Jobs out of its image comparison (found by
#     running it, not by reasoning about it, per that script's own header).
#   - **Everything that is not a Deployment or a NetworkPolicy** - ConfigMaps, Secrets, Services,
#     Certificates, the namespace itself. Not because they cannot drift, but because this item's own
#     incident and its own Done-when name "a manifest change that a `kubectl set image` roll would not
#     deliver" - env, probes, spec, NetworkPolicy - and widening the comparison without a second
#     incident to justify it is exactly the "generic check nobody can explain" `smoke.sh`'s own header
#     argues against repeating.
#
# WHAT A NONZERO EXIT MEANS, AND WHAT IT DOES NOT. This script's own exit code is never allowed to
# fail `redeploy.sh` - the deploy that already happened (images moved, migrations applied, smoke
# green) does not become undone by a check running after it, and a check that can *only* warn must
# never be wired to look like the thing it is warning about. `redeploy.sh` calls this last, after its
# own closing note, with the exit code discarded on purpose. Read the printed banner instead:
#   PASS   - the manifest and the cluster agree on everything this script compares.
#   DRIFT  - they do not; the diff is printed, and so is what to do about it.
#   UNKNOWN - the comparison could not be made (no cluster reached, or `kubectl diff` itself errored
#             for a reason this script did not anticipate). Reported as unknown, not folded into PASS -
#             a check that cannot tell "drifted" from "cannot tell" is worse than no check at all.
#
# THE ORDER THAT AVOIDS THE DEADLOCK. `apply-demo.sh` refuses to apply while the overlay's image pins
# are behind the cluster (`22-24`) - which is exactly the state a redeploy leaves behind until the
# tags are committed. So a DRIFT banner here is only actionable in this order: commit the tags
# `redeploy.sh`'s own closing note just printed, *then* run `./apply-demo.sh`. Running `apply-demo.sh`
# first, before that commit, hits the other script's own refusal - correctly, since the pins really
# are still behind at that point.
#
# Run standalone from the node, or from anywhere for a dry render (the diff step itself needs cluster
# access and reports UNKNOWN without it):
#   cd ~/ago/ago-deploy/k8s && ./check-manifest-drift.sh [overlay-name]
#
# Environment:
#   NS   namespace   (default: ago-chat)
set -uo pipefail

OVERLAY="${1:-demo}"
NS="${NS:-ago-chat}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$HERE/overlays/$OVERLAY"

# Same probe every other script here uses: a `kubectl` on the PATH is not proof it can reach the
# cluster, since k3s keeps its kubeconfig root-only and a wrapper that forgets sudo passes
# `command -v` happily.
kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

step "Manifest drift (${OVERLAY})"

if ! kc get ns "$NS" >/dev/null 2>&1; then
  echo "   UNKNOWN - no cluster reached (NS=${NS}). Run this on the node to get a real answer."
  exit 0
fi

rendered="$(mktemp)"
filtered="$(mktemp)"
normalized="$(mktemp)"
sed_script="$(mktemp)"
trap 'rm -f "$rendered" "$filtered" "$normalized" "$sed_script"' EXIT

if ! kc kustomize "$OVERLAY_DIR" > "$rendered" 2>/dev/null; then
  echo "   UNKNOWN - 'kubectl kustomize ${OVERLAY_DIR}' failed to render. Run it directly to see why" \
       "(a missing gitignored input - .env, .env.telegram-relay, internal-ca.key - is the usual cause)."
  exit 0
fi

# Keep only Deployment and NetworkPolicy documents - an allowlist, not a blocklist for Job alone,
# because "everything except the two migrators" would also feed ConfigMaps, Secrets, Certificates and
# the Gateway API resources into the diff, none of which this script's own header claims to compare
# and several of which can churn for reasons that are not drift (a configMapGenerator's content-hash
# suffix changing the object's own name, a cert-manager CRD not being in a dry-run client's discovery
# cache). Narrower on purpose: widen this allowlist only when a real incident, named the way `23-45`
# is named above, justifies the next kind.
#
# Kustomize separates documents with a bare '---' line; each document here is buffered and only
# printed once its own 'kind:' line is known to be one of the two kept kinds.
awk '
  BEGIN { doc = ""; keep = 0 }
  /^---[[:space:]]*$/ {
    if (doc != "" && keep) printf "%s---\n", doc
    doc = ""; keep = 0
    next
  }
  {
    if ($0 == "kind: Deployment" || $0 == "kind: NetworkPolicy") keep = 1
    doc = doc $0 "\n"
  }
  END { if (doc != "" && keep) printf "%s", doc }
' "$rendered" > "$filtered"

# Build one sed rewrite per image repository this namespace is actually running, from the live
# Deployments - not from the manifest, so a Deployment the manifest does not mention yet cannot
# contribute a rule. Repository name only (everything left of ':') is the key: it is what a
# Deployment's own name does not reliably match (e.g. ago-demo-shop1 and ago-demo-shop2 share one
# ago-widget image, ago-chat-migrator's repository never appears in a Deployment at all), while the
# repository path appears in the manifest exactly once per image and is what actually varies.
#
# `[a-z0-9-]+`, not `[a-z-]+`: two repository names in this overlay carry a digit
# (ago-demo-shop1, ago-demo-shop2), and a class that excludes digits fails to match either -
# silently, since grep just finds no line rather than an obviously wrong one. Found while building
# this script, by noticing `apply-demo.sh`'s own image-comparison regex has the identical class and
# therefore never covers those two Deployments in its own rollback guard either - worth its own
# ticket, not this one; `apply-demo.sh`'s refusal is explicitly out of this item's scope.
kc get deploy -n "$NS" \
  -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | grep -E '^ghcr\.io/golyakoff/[a-z0-9-]+:[0-9a-f]{40}$' | sort -u \
  | while IFS=: read -r repo livetag; do
      # Escape nothing beyond what these values ever contain (lowercase letters, hyphens, hex, dots,
      # slashes) - none of it is sed-special, so a plain substitution is enough.
      printf 's#%s:[0-9a-f]\\{40\\}#%s:%s#g\n' "$repo" "$repo" "$livetag"
    done > "$sed_script"

if [ ! -s "$sed_script" ]; then
  echo "   UNKNOWN - could not read any running image from Deployments in ${NS}; the image-tag" \
       "normalization this check depends on has nothing to work from."
  exit 0
fi
sed -f "$sed_script" "$filtered" > "$normalized"

diff_out="$(kc diff -f "$normalized" 2>&1)"
rc=$?

case "$rc" in
  0)
    echo "   PASS - the manifest and the cluster agree (Deployments and NetworkPolicies, image tags aside)."
    ;;
  1)
    echo "   DRIFT - the manifest carries a change 'kubectl set image' would not have delivered:"
    echo
    echo "$diff_out" | sed 's/^/   /'
    echo
    echo "   If the tags redeploy.sh just printed still need committing, commit those first - then:"
    echo "     cd $HERE && ./apply-demo.sh"
    echo "   (apply-demo.sh refuses while the committed pins are behind the cluster, 22-24 - committing"
    echo "   the tags first is what clears that refusal before this drift can be applied.)"
    ;;
  *)
    echo "   UNKNOWN - 'kubectl diff' itself failed (exit ${rc}), rather than reporting a diff:"
    echo
    echo "$diff_out" | sed 's/^/   /'
    echo
    echo "   Treat this as 'cannot tell', not as 'clean' - a check that reports PASS here would be"
    echo "   worse than no check at all."
    ;;
esac
exit 0
