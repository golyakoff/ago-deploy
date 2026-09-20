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
#   - **Everything that is not a Deployment or a NetworkPolicy**, for *content* - ConfigMaps, Secrets,
#     Services, HTTPRoutes, Certificates, the namespace itself. Not because they cannot drift, but
#     because this item's own incident and its own Done-when name "a manifest change that a
#     `kubectl set image` roll would not deliver" - env, probes, spec, NetworkPolicy - and widening the
#     comparison without a second incident to justify it is exactly the "generic check nobody can
#     explain" `smoke.sh`'s own header argues against repeating. `25-188` below adds Services and
#     HTTPRoutes back in, but only for *existence*, not content - a narrower question with its own
#     incident to justify it.
#
# WHAT ELSE THIS COMPARES (`25-188`). Existence, not content, and only for Deployments/Services/
# HTTPRoutes: every one of those three kinds actually running in the namespace, against the same
# kinds in the rendered overlay - flagging a name that runs live but is not in the manifest any more.
# `apply -k` (no `--prune`) only ever adds or updates what the manifest currently lists; it never
# deletes what used to be listed and is not any more. `25-182` removed `ago-demo-shop2` from this
# overlay and its own `Deployment`/`Service`/`HTTPRoute` all kept running regardless, found only
# because that item's own Done-when asked for a live check by hand - this is the check that would have
# said so instead. See the comment directly above `manifest_names` below for why `--prune` itself was
# not the fix chosen.
#
# WHAT A NONZERO EXIT MEANS, AND WHAT IT DOES NOT (`15-24`). The banner is the primary signal either
# way - read it. But the exit code now tells the same story, for a standalone caller or a human who
# checks `$?` instead of the text: `0` for PASS, `1` for DRIFT (a real difference is printed - the
# `check-theme-tokens.sh`/`deploy.sh` convention already used in this directory for "found a problem"),
# `2` for UNKNOWN (no cluster reached, a filtering step failed, or `kubectl diff` itself errored for a
# reason this script did not anticipate - the same directory's convention for "could not tell", distinct
# from both PASS and DRIFT so a failed `awk` or `sed` can never read back as either).
#   PASS   - the manifest and the cluster agree on everything this script compares.
#   DRIFT  - they do not; the diff is printed, and so is what to do about it.
#   UNKNOWN - the comparison could not be made. Reported as unknown, not folded into PASS - a check
#             that cannot tell "drifted" from "cannot tell" is worse than no check at all.
# `redeploy.sh` and `deploy.sh` still call this last and still discard the exit code with `|| true` -
# that does not change here, and is not this item's to revisit (`adr/0144`): the deploy that already
# happened (images moved, migrations applied, smoke green) must never become undone by a check that
# runs after it. What changes is what `|| true` is doing: before `15-24` every path through this script
# ended in `exit 0`, so the `|| true` at both call sites discarded a status that could never have been
# anything else - decorative, not defensive. Giving DRIFT and UNKNOWN real nonzero codes makes that
# `|| true` documentation of a deliberate choice (advisory, never fatal, per `adr/0144`) instead of dead
# syntax, and it means a future caller that does not want that choice - a CI gate, an operator's own
# script - has something to check. The alternative, leaving every path at `exit 0` and saying so plainly
# here instead, was rejected: it is simpler, but it leaves `|| true` permanently unable to mean anything
# and gives a future standalone invocation ("run standalone from the node" - see below) no way to act on
# DRIFT/UNKNOWN without re-parsing the banner text. Nonzero costs nothing here, because the two callers
# already choose to swallow it.
#
# THE ORDER THAT AVOIDS THE DEADLOCK. `apply-demo.sh` refuses to apply while the overlay's image pins
# are behind the cluster (`22-24`) - which is exactly the state a redeploy leaves behind until the
# tags are committed. So a DRIFT banner here is only actionable in this order: commit the tags
# `redeploy.sh`'s own closing note just printed, *then* run `./apply-demo.sh`. Running `apply-demo.sh`
# first, before that commit, hits the other script's own refusal - correctly, since the pins really
# are still behind at that point.
#
# Run standalone from the node, or from anywhere for a dry render (the diff step itself needs cluster
# access and reports UNKNOWN, exit 2, without it):
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

# `23-90`: record_check - sourced after kc()/step() are defined, matching lib-deploy-record.sh's own
# stated contract (it calls both, defines neither).
# shellcheck source=lib-deploy-record.sh
. "$HERE/lib-deploy-record.sh"

step "Manifest drift (${OVERLAY})"

if ! kc get ns "$NS" >/dev/null 2>&1; then
  echo "   UNKNOWN - no cluster reached (NS=${NS}). Run this on the node to get a real answer."
  exit 2
fi

rendered="$(mktemp)"
filtered="$(mktemp)"
normalized="$(mktemp)"
sed_script="$(mktemp)"
trap 'rm -f "$rendered" "$filtered" "$normalized" "$sed_script"' EXIT

if ! kc kustomize "$OVERLAY_DIR" > "$rendered" 2>/dev/null; then
  echo "   UNKNOWN - 'kubectl kustomize ${OVERLAY_DIR}' failed to render. Run it directly to see why" \
       "(a missing gitignored input - .env, .env.telegram-relay, internal-ca.key - is the usual cause)."
  exit 2
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
#
# `15-24`: this step has no `-e` to catch it and no pipe for `pipefail` to watch, so a failure here
# leaves $filtered empty exactly the way "the overlay genuinely has no Deployment or NetworkPolicy"
# would - and an empty $filtered makes every later diff against it come back clean. Checked the same
# way the `kubectl kustomize` step above checks itself: the command's own exit status, not the
# emptiness of what it wrote, because emptiness is also the correct output for an overlay this script
# doesn't understand rather than one whose filter broke.
if ! awk '
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
' "$rendered" > "$filtered"; then
  echo "   UNKNOWN - the Deployment/NetworkPolicy filter itself failed reading the rendered overlay;" \
       "run 'kubectl kustomize ${OVERLAY_DIR}' and pipe it through the awk step by hand to see why."
  exit 2
fi

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
  exit 2
fi

# `15-24`: same gap as the awk step above - no failure check of its own, so a broken $sed_script (or a
# sed that cannot read $filtered) would leave $normalized empty and read back as a clean diff rather
# than as a tool failure. Checked on exit status, matching the awk and kustomize checks either side of
# it, not on emptiness - $normalized is legitimately empty whenever $filtered was (an overlay with no
# Deployments or NetworkPolicies), and that is not a failure this step should be reporting.
if ! sed -f "$sed_script" "$filtered" > "$normalized"; then
  echo "   UNKNOWN - the image-tag normalization ('sed -f' against the filtered overlay) itself failed;" \
       "the \$sed_script is a temp file this run's trap already deleted, so rerun this script to" \
       "regenerate it and reproduce the failure - the rules that build it are in the comment above."
  exit 2
fi

diff_out="$(kc diff -f "$normalized" 2>&1)"
rc=$?

# `kubectl diff`'s own exit convention already lines up with `15-24`'s (0 clean, 1 a real diff, other
# "the comparison itself failed"), so `rc` doubles as this script's own exit code below rather than
# being remapped through a second variable.
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
    echo "   (apply-demo.sh refuses a *rollback* - pins naming a tag this cluster has already run,"
    echo "   22-24 as narrowed by 23-110. Committing the tags redeploy just used is what clears that,"
    echo "   because it stops the manifest pointing backwards. A manifest deliberately ahead of the"
    echo "   cluster - freshly published CI images - is a roll-forward and needs no flag.)"
    ;;
  *)
    echo "   UNKNOWN - 'kubectl diff' itself failed (exit ${rc}), rather than reporting a diff:"
    echo
    echo "$diff_out" | sed 's/^/   /'
    echo
    echo "   Treat this as 'cannot tell', not as 'clean' - a check that reports PASS here would be"
    echo "   worse than no check at all."
    rc=2
    ;;
esac

# `25-188`: a second, independent comparison - existence, not content. `apply-demo.sh` (and a bare
# `kubectl apply -k`) never carries `--prune`, so a resource dropped from the overlay - a static-site
# file deleted, an `HTTPRoute` block removed, two Deployments folded into one - keeps running and
# keeps being routed to until somebody deletes it by hand. `25-182` did exactly that to
# `ago-demo-shop2` and its own `Deployment`/`Service`/`HTTPRoute` all outlived the manifest edit,
# found only because that item's own Done-when asked for a live check. This is the "manifest and
# cluster must agree" posture this file's own header already states for image tags (`WHAT THIS
# COMPARES`, above), extended from *version* to *existence*.
#
# **`Deployment`/`Service`/`HTTPRoute` only, not every kind `apply -k` manages.** These three are the
# kinds a resource orphaned this way stays live and reachable through - a stale `Deployment` keeps
# serving traffic, a stale `Service` keeps a ClusterIP routing to it, a stale `HTTPRoute` keeps sending
# public traffic there - which is exactly the `25-182` incident's own shape. `ConfigMap`/`Secret`
# names churn on their own content-hash suffix by kustomize's own design (`configMapGenerator`'s
# comment elsewhere in this repository) and an old hash left behind is expected garbage, not the
# silent-orphan failure this item is about; widening past these three kinds without a second incident
# naming one is the same restraint this file's header already argues for the Deployment/NetworkPolicy
# diff above.
#
# **Considered and not built: `kubectl apply -k --prune`.** Kustomize's own prune needs a label
# selector scoping exactly what it may delete, and `overlays/demo`'s own resources carry no common
# label today - no `commonLabels`/`labels:` transformer in `kustomization.yaml`, and every static
# Deployment/Service pair here (e.g. `demo-shop1-static.yaml`) sets only its own per-resource `app:`
# label, which differs by name and cannot double as a "these are mine" selector. Introducing one now
# would mean adding a label kustomize's `labels:` transformer also writes into `matchLabels`/selector
# fields - and a Deployment's `spec.selector.matchLabels` is immutable, so that same edit could refuse
# to apply against a live Deployment that predates it. Proving that either way needs a real cluster,
# which this item does not have (its own Done-when says so); reading the overlay's own manifests
# locally is what found the missing label in the first place. Existence-checking here, against the
# same rendered overlay this whole script already trusts, needed no assumption a real cluster would
# have to confirm.
manifest_names="$(awk '
  BEGIN { kind = "" }
  /^kind: / { kind = $2 }
  /^  name: / && kind != "" {
    if (kind == "Deployment" || kind == "Service" || kind == "HTTPRoute") print kind "/" $2
    kind = ""
  }
' "$rendered" | sort -u)"

step "Live resources with no match in the rendered overlay"

if ! cluster_names="$(kc get deployment,service,httproute -n "$NS" \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}{"\n"}{end}' 2>/dev/null | sort -u)"; then
  echo "   UNKNOWN - could not list Deployments/Services/HTTPRoutes in ${NS}."
  orphan_rc=2
elif [ -z "$cluster_names" ]; then
  echo "   UNKNOWN - the cluster reported no Deployment, Service or HTTPRoute at all in ${NS}, which"
  echo "   this overlay always defines several of - treating an empty list as a match would hide a"
  echo "   cluster this check could not actually reach."
  orphan_rc=2
else
  orphans="$(comm -23 <(printf '%s\n' "$cluster_names") <(printf '%s\n' "$manifest_names"))"
  if [ -n "$orphans" ]; then
    echo "   DRIFT - these are running in ${NS} but the rendered overlay no longer defines them:" >&2
    printf '%s\n' "$orphans" | sed 's/^/     /' >&2
    echo "   apply -k never deletes a resource removed from the manifest (no --prune) - see" >&2
    echo "   docs/runbooks/redeploy.md's own removal procedure for how to take these down by hand." >&2
    orphan_rc=1
  else
    echo "   every Deployment/Service/HTTPRoute running in ${NS} is still in the rendered overlay."
    orphan_rc=0
  fi
fi

# `23-90`: a third, independent comparison - reading B ("the next run") for the gap the tag
# normalisation above deliberately cannot see (this file's own header, "WHAT IT DELIBERATELY
# IGNORES"). Run every time this script runs, not only from deploy.sh/redeploy.sh's own tail call, so
# a standalone `./check-manifest-drift.sh` - not tied to any deploy - catches an unrecorded gap too,
# exactly as `23-90`'s own "Answered" section asks for.
#
# No `|| true` here, unlike deploy.sh's/redeploy.sh's own calls into this file: this script has no
# `set -e` (only `set -uo pipefail`, this file's own header), so record_check returning non-zero
# cannot abort it - and `|| true` would have thrown away that exit code before the next line could
# read it. Found live, not reasoned about: an earlier version of this line had the `|| true` anyway
# (copied from the two callers' own convention without checking whether it applied here too) and
# `record_rc` read back 0 on every run regardless of what record_check actually returned, because
# `cmd || true`'s own exit status is `true`'s, not `cmd`'s.
record_check "$NS" "$OVERLAY_DIR"
record_rc=$?

# Combine into one exit code rather than inventing a fourth PASS/DRIFT/UNKNOWN state (`15-24`'s
# convention, which this item's own Done-when explicitly says to keep). DRIFT outranks UNKNOWN in the
# combination, deliberately: DRIFT from any sub-check is a confirmed, actionable gap, while UNKNOWN
# only means one sub-check could not be evaluated - a real, specific problem should never be hidden by
# an unrelated "cannot tell" from another comparison. `25-188` added `orphan_rc` as a third sub-check
# alongside the field diff (`rc`) and the deploy record (`record_rc`); it folds into the same two-value
# combination rather than a fourth state, for the identical reason `record_rc` did.
if [ "$rc" -eq 1 ] || [ "$record_rc" -eq 1 ] || [ "$orphan_rc" -eq 1 ]; then
  rc=1
elif [ "$rc" -eq 2 ] || [ "$record_rc" -eq 2 ] || [ "$orphan_rc" -eq 2 ]; then
  rc=2
else
  rc=0
fi
exit "$rc"
