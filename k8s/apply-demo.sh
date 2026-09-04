#!/usr/bin/env bash
# Apply `overlays/demo` the way an operator actually reaches for it: after `deploy.sh` names the
# `newTag` values that moved and says to commit them (its own closing "Keep the manifest honest"
# note), the very next step is `kubectl apply -k overlays/demo` to make the record match the cluster.
#
# `8-12` / ago-root#361: that plain `apply -k` fails the moment a migrator's pin is among the tags
# that moved. A `Job`'s `spec.template` is immutable, and `8-08` ties both migrators' tags to their
# hosts', so a routine host bump routinely bumps a migrator tag too - the failure is not an edge case
# reachable only by mistake, it is on the path `deploy.sh` itself just pointed the operator down.
# `kubectl diff -k` fails identically, which is the worse half: it reports a *difference* rather than
# an inapplicable manifest, so the operator goes looking for drift that was never there.
#
# THE SHAPE CHOSEN, AND WHAT IT REPLACES. `redeploy.sh` already carries the fix - `run_migrator`
# deletes each migrator Job before re-applying it, because a Job whose pod template changed can only
# be replaced, never patched. That knowledge just never sat on the path anyone walks after `deploy.sh`,
# whose own next-step note names `apply -k` directly. This script is that path: a thin wrapper that
# does the one thing `apply -k` cannot - clear a finished Job out of the way first - and then runs the
# exact command the note already tells the operator to run. It replaces "run `kubectl apply -k
# overlays/demo` by hand and, on the immutable-field error, work out from a 3KB pod-spec dump that the
# fix is `kubectl delete job` and try again" with "run this instead". `apply -k` itself is untouched -
# nothing here weakens what a from-scratch cluster gets by applying the overlay directly, since a Job
# that does not exist yet is simply created, the same as any other resource.
#
# THE OTHER TWO SHAPES `ago-root#361` NAMED, AND WHY NEITHER IS THIS FILE:
#   - `ttlSecondsAfterFinished` on both Jobs so a finished one self-deletes and the next `apply -k`
#     recreates it clean. Both Jobs already carry one - 3600s, from `8-08`/`8-10`'s own reasoning
#     ("long enough to read the logs of a failed run... not measured, a shape"). It does not close
#     this ticket: the failure this item reproduces happens *inside* that hour, immediately after the
#     tag that triggers it, which is exactly when `deploy.sh`'s closing note sends the operator
#     straight at `apply -k`. Shortening the TTL to make that window small trades directly against the
#     reason `8-08` picked an hour in the first place - a completed migrator's logs are what a *failed*
#     migration leaves behind to read, and `redeploy.sh` prints them on failure precisely because they
#     matter. A TTL of 0 would race exactly that: a Job that deletes itself the moment it fails takes
#     its own diagnostic with it, before anyone - this script, a human, or `redeploy.sh`'s own
#     `kc logs` call - is guaranteed to have read it. Left unchanged here rather than tuned, because
#     tuning it cannot fix the near-term case this item is about without reopening the case `8-08`
#     already closed.
#   - Leaving `apply -k` alone and documenting the trap in `redeploy.md` beside `deploy.sh`'s own
#     note. Not this item's to do - ago-root's docs are the author's own, by standing instruction -
#     and answering with documentation only would leave the ordinary path still walking into the
#     failure. Worth naming what this script's existence does NOT make true: `redeploy.md`'s own
#     sentence "`redeploy.sh` ... never runs `kubectl apply -k`. ... a change that lives only in
#     `ago-deploy/k8s/` does not reach the node through this script" stays exactly as true as it was -
#     this is a second, sibling entry point, not a change to what `redeploy.sh` covers.
#
# A FOURTH POSSIBILITY, EVALUATED AND NOT ADOPTED: could `apply -k` be made to succeed on its own,
# with nothing to delete? Two variants, both dead ends already on record or in principle:
#   - Move the migrator Jobs out of the overlay's default resource list, into a kustomization applied
#     separately. `redeploy.sh`'s own comment on this exact idea (above `run_migrator`) already tried
#     it: kustomize refuses a `resources:` path outside its own root, so a standalone kustomization
#     under `k8s/` cannot reach `base/migrator.yaml` at all. The only way that comment's workaround
#     works today - render the *whole* overlay and filter with `-l app=<job>` - still requires the Job
#     to be a resource `apply -k` sees, which is the thing this variant tries to avoid.
#   - Give the Job a generated, content-addressed name (kustomize's own trick for ConfigMap/Secret),
#     so a changed pin produces a new object instead of a patch to an old one. Kustomize does not
#     extend that hashing to `Job`. The alternative, `metadata.generateName`, is a `kubectl create`
#     mechanism with no stable identity for `apply` to reconcile against - every re-apply would mint a
#     new random name, and both `redeploy.sh`'s `kc wait --for=condition=complete job/<fixed-name>`
#     and its `-l app=<job>` rerun would have nothing fixed left to address. Fixing that is
#     `redeploy.sh`'s own file, out of this item's lane by the same rule that keeps `15-13`'s work out
#     of it.
# Both would also still need this script's own answer to the harder question below (a running Job
# must never be deleted), so neither buys back the safety check - only the "nothing to delete" framing.
#
# A COMPLETED JOB IS NOT A RUNNING ONE, so this does not delete unconditionally the way `redeploy.sh`
# can afford to (redeploy.sh is itself the thing that just started that Job's run, on a path with no
# concurrent operator). Before deleting, this checks `.status.active` - a Job with an active pod is
# left alone and the script refuses to touch it, on the reasoning that killing a migration mid-run is
# a strictly worse outcome than a plain apply -k failure that a person can still read and act on. This
# is a narrow window, not a lock: a Job that has just been created and has not yet reported
# `.status.active` would pass this check before its pod starts. Stated rather than hidden - see the
# report this script's own item closes out with for what remains unverified.
#
# Run from the node, or against docker-desktop for a dry run of this exact sequence:
#   cd ~/ago/ago-deploy/k8s && ./apply-demo.sh
#
# Environment:
#   NS   namespace       (default: ago-chat)
set -euo pipefail

NS="${NS:-ago-chat}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same probe deploy.sh/redeploy.sh use: a `kubectl` on the PATH is not proof it can reach the
# cluster, since k3s keeps its kubeconfig root-only and a wrapper that forgets sudo passes
# `command -v` happily.
kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

# `22-24`: **refuse to roll a deployment backwards.** `redeploy.sh` moves images imperatively with
# `kubectl set image` and closes by asking the operator to commit the tags it just used. Until that
# commit happens the manifest still pins the *previous* tags, so `apply -k` on top of a redeploy is
# not a no-op - it is a rollback, silently, ending in a success message.
#
# That happened on 2026-09-04. A redeploy moved three chat hosts, two calendar hosts and the console
# forward; this script ran next; every one of them went back to the tag in the file. The migrations
# had already been applied forward, so the cluster ran older code against a newer schema until it was
# noticed. `redeploy.sh`'s own smoke had passed minutes earlier - against the pods that were then
# replaced - and the only visible symptom was one failing check whose cause was three layers away.
#
# The check is a set comparison rather than a per-deployment one, deliberately: mapping a rendered
# manifest back to each Deployment needs indentation-sensitive parsing that fails quietly, and the
# question here does not need it. "Would this apply introduce an image tag that is nothing is running
# right now?" is enough to catch a rollback, and it cannot mis-attribute.
#
# **Deployments only, not Jobs.** The migrator Jobs are deleted and recreated by this very script,
# and `8-08` ties their tags to their hosts', so between a redeploy and this apply they legitimately
# carry the older tag - including them made the guard refuse a correct forward apply. Found by
# running it, not by reasoning about it.
#
# A migrator image appears *only* in a Job, never in a Deployment, so it has to leave the manifest
# side of the comparison as well - otherwise it is permanently "not running" and the guard refuses
# every apply. That is the second thing running it taught: the guard protects the workloads that
# serve traffic, and the migrator is recreated from the manifest on every run by design.
#
# `--force-rollback` keeps a deliberate rollback possible while an accidental one is not.
FORCE_ROLLBACK=0
for arg in "$@"; do [ "$arg" = "--force-rollback" ] && FORCE_ROLLBACK=1; done

step "Comparing the manifest's image tags against what is running"
manifest_imgs="$(kc kustomize "$HERE/overlays/demo" 2>/dev/null   | grep -oE "image: ghcr\.io/golyakoff/[a-z-]+:[0-9a-f]{40}" | sed 's/image: //'   | grep -v -- "-migrator:" | sort -u)"
running_imgs="$(kc get deploy -n "$NS"   -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}'   | grep -E "^ghcr\.io/golyakoff/" | sort -u)"
would_introduce="$(comm -23 <(printf '%s\n' "$manifest_imgs") <(printf '%s\n' "$running_imgs"))"

if [ -n "$would_introduce" ]; then
  echo "   this apply would move these to a tag nothing is running:" >&2
  printf '%s\n' "$would_introduce" | sed 's|ghcr.io/golyakoff/|     |' >&2
  if [ "$FORCE_ROLLBACK" = "1" ]; then
    echo "   --force-rollback given, continuing." >&2
  else
    echo >&2
    echo "   Refusing to apply. If a redeploy just ran, the manifest is behind the cluster:" >&2
    echo "   commit the tags it used (its own \"Keep the manifest honest\" note) and run this again." >&2
    echo "   If you really do mean the tags in the file: $0 --force-rollback" >&2
    exit 1
  fi
else
  echo "   every image the manifest pins is already running"
fi

step "Clearing finished migrator Jobs out of apply -k's way"
for job in ago-chat-migrator ago-calendar-migrator; do
  if ! kc get job "$job" -n "$NS" >/dev/null 2>&1; then
    echo "   ${job}: not present - nothing to clear"
    continue
  fi
  active="$(kc get job "$job" -n "$NS" -o jsonpath='{.status.active}')"
  if [ -n "$active" ] && [ "$active" != "0" ]; then
    echo "   ${job}: has ${active} active pod(s) - a migration is running. Refusing to delete it." >&2
    echo "   Re-run this script once it finishes (kubectl get job ${job} -n ${NS})." >&2
    exit 1
  fi
  echo "   ${job}: finished, deleting so apply -k can recreate it"
  kc delete job "$job" -n "$NS"
done

step "kubectl apply -k overlays/demo"
kc apply -k "$HERE/overlays/demo"

step "Migrator Jobs after apply"
kc get job ago-chat-migrator ago-calendar-migrator -n "$NS" 2>/dev/null || true
echo
echo "  A Job just (re)created by the apply above is not necessarily finished yet - unlike"
echo "  redeploy.sh's own run_migrator, this script does not wait for it. Check with:"
echo "    kubectl get job ago-chat-migrator ago-calendar-migrator -n ${NS}"
echo "  and read a failure's logs with:"
echo "    kubectl logs job/<name> -n ${NS}"
