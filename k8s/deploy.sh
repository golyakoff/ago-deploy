#!/usr/bin/env bash
# Deploy a specific, identifiable build to the demo cluster.
#
#   ./deploy.sh <commit-sha>            the three Ago.Chat.* hosts, together
#   ./deploy.sh <frontend> <commit-sha> one frontend: console | demo-shop1 | demo-shop2 | landing
#   ./deploy.sh --current               print what is running and stop
#
# One commit argument for the hosts because all three are built from one repository, and one
# frontend at a time because the four are built from three repositories that move independently -
# `15-07`. A single tag applied to all seven would be a lie about at least two of them.
#
# `15-06`/`adr/0047`. Before this existed, a deploy meant rebuilding on the node under the mutable
# tag `:local` - so there was no earlier artifact to go back to, and nothing about a running pod
# said which commit was in it. On 2026-08-25 that cost twice in one day: a console bundle a week
# stale, and no way to tell. redeploy.sh made the sequence repeatable; it could not make it
# identifiable, because identity is a property of the artifact, not of the procedure.
#
# What this script deliberately is NOT: it does not build, pull the checkouts, or run migrations.
# It moves the cluster to an already-published artifact. redeploy.sh is still the build-from-source
# path, and migrations remain its job - read the "Migrations and rollback" note at the bottom of
# this file before rolling anything back, because that asymmetry is the part usually got wrong.
set -euo pipefail

NS="${NS:-ago-chat}"
DOMAIN="${DOMAIN:-reserve-me.ru}"
REGISTRY="${REGISTRY:-ghcr.io/golyakoff}"
AGO_ROOT="${AGO_ROOT:-$HOME/ago}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same probe redeploy.sh uses: a `kubectl` on the PATH is not proof it can reach the cluster, since
# k3s keeps its kubeconfig root-only and a wrapper that forgets sudo passes `command -v` happily.
kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

# deployment:container - `kubectl set image` addresses the container by name, not by position.
HOSTS=("ago-chat-api:api" "ago-chat-worker:worker" "ago-chat-webhooks:webhooks")

# `15-07`: name-as-typed:deployment. The container name equals the Deployment name for all four
# (overlays/demo/*-static.yaml), so one field is enough here where the hosts needed two.
FRONTENDS=("console:ago-console" "demo-shop1:ago-demo-shop1" "demo-shop2:ago-demo-shop2" "landing:ago-landing")

# The commit a running pod reports about itself, asked over the API server's own pod proxy. Two
# shapes, one idea:
#
#   - the .NET hosts serve GET /healthz/version on 8080, out of the compiled assembly. They are
#     Chiseled images - no shell, no curl, nothing to `kubectl exec` - so the proxy is not a
#     convenience here, it is the only way to ask without starting a helper pod that would itself
#     need an image pulled from somewhere.
#   - the four frontends serve /version.json on 80, written into the image at build time (15-07).
#     A browser bundle has no process to interrogate, so the artifact has to carry the answer as a
#     file. Same question, same parsing, one column below.
pod_commit() {
  local app="$1" port="$2" path="$3" pod
  pod="$(kc get pod -n "$NS" -l "app=$app" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -z "$pod" ] && { echo unreadable; return; }
  kc get --raw "/api/v1/namespaces/${NS}/pods/${pod}:${port}/proxy/${path}" 2>/dev/null \
    | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' | head -1 | grep . || echo unreadable
}

show_row() {
  local d="$1" commit="$2" tag
  tag="$(kc get deployment "$d" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  # The tag is a label somebody chose; the commit comes out of the artifact. Printing both side by
  # side is the point - they agree until a tag is re-pushed or a manifest edited by hand, and the
  # first time they disagree is the day this pairing earns its place.
  printf "  %-20s %-42s %s\n" "$d" "${tag##*:}" "$commit"
}

show_current() {
  printf "  %-20s %-42s %s\n" DEPLOYMENT "IMAGE TAG (what was asked for)" "COMMIT (what is running)"
  for entry in "${HOSTS[@]}"; do
    d="${entry%%:*}"
    show_row "$d" "$(pod_commit "$d" 8080 healthz/version)"
  done
  # `15-07`: the frontends are here for the same reason the hosts are, and it is not symmetry for
  # its own sake - the 2026-08-25 stale bundle was a *console*, so this half of the table is the
  # half that would have caught the incident this whole mechanism exists for.
  for entry in "${FRONTENDS[@]}"; do
    d="${entry##*:}"
    show_row "$d" "$(pod_commit "$d" 80 version.json)"
  done
}

if [ "${1:-}" = "--current" ]; then
  step "What is running now"
  show_current
  exit 0
fi

usage() {
  echo "usage: $0 <commit-sha> | $0 <console|demo-shop1|demo-shop2|landing> <commit-sha> | $0 --current" >&2
  exit 2
}

# One argument means the three hosts (unchanged from 15-06). Two means a single frontend.
COMPONENT=""
if [ "$#" -eq 2 ]; then
  COMPONENT="$1"; TAG="$2"
  DEPLOYMENT=""
  for entry in "${FRONTENDS[@]}"; do
    [ "${entry%%:*}" = "$COMPONENT" ] && DEPLOYMENT="${entry##*:}"
  done
  if [ -z "$DEPLOYMENT" ]; then
    echo "unknown component '$COMPONENT'." >&2
    usage
  fi
elif [ "$#" -eq 1 ]; then
  TAG="$1"
else
  usage
fi

# A tag that cannot name a commit cannot be rolled back to, which is the whole reason this script
# exists - so refuse one here rather than discovering it during an incident. `main` and `latest` are
# rejected by the same rule, deliberately: both are moving targets that describe a moment, not a
# build.
if ! printf '%s' "$TAG" | grep -qE '^[0-9a-f]{40}$'; then
  echo "refusing '$TAG': the tag must be a full 40-character commit SHA (adr/0047)." >&2
  echo "  Every repository's CI publishes exactly that on every push to main; 'main' and 'latest'" >&2
  echo "  move and therefore cannot be deployed or rolled back to." >&2
  exit 2
fi

# The set of Deployments this invocation moves, and the image name each takes. The two paths differ
# only in what goes in these two arrays, so everything below - rollout waiting, failure handling,
# the manifest reminder, smoke - is written once (`15-07`).
TARGETS=()   # deployment names
IMAGES=()    # deployment=image, for `kubectl set image`
if [ -n "$COMPONENT" ]; then
  TARGETS=("$DEPLOYMENT")
  IMAGES=("$DEPLOYMENT=${REGISTRY}/${DEPLOYMENT}:${TAG}")
  DESCRIPTION="${REGISTRY}/${DEPLOYMENT}:${TAG}"
  MANIFEST_HINT="the newTag for ${DEPLOYMENT} in"
else
  for entry in "${HOSTS[@]}"; do
    d="${entry%%:*}"; c="${entry##*:}"
    TARGETS+=("$d")
    IMAGES+=("${c}=${REGISTRY}/${d}:${TAG}")
  done
  DESCRIPTION="${REGISTRY}/ago-chat-{api,worker,webhooks}:${TAG}"
  MANIFEST_HINT="all three ago-chat-* newTag values in"
fi

step "Deploying $TAG"
show_current
echo
echo "  -> ${DESCRIPTION}"

step "Setting images"
for i in "${!TARGETS[@]}"; do
  kc set image "deployment/${TARGETS[$i]}" "${IMAGES[$i]}" -n "$NS"
done

# The API first and on its own, matching redeploy.sh's own ordering note: the console calls the API,
# so an API that is behind is the failure mode worth avoiding. Here all three move together, so the
# ordering only decides which failure surfaces first - and the API is the one worth learning about
# first, because it is the one a rollback has to save.
step "Waiting for rollouts"
for d in "${TARGETS[@]}"; do
  # A pull failure (wrong tag, package still private) never terminates the old pod: the rolling
  # update simply stalls with maxUnavailable respected, so service continues while this times out.
  # That is the safety property worth knowing - a broken *image reference* cannot take the site
  # down, whereas a broken *application* can, and only the second one needs a rollback.
  if ! kc rollout status "deployment/$d" -n "$NS" --timeout=180s; then
    echo
    echo "  $d did not become ready. The previous ReplicaSet is still serving." >&2
    kc get pods -n "$NS" -l "app=$d" >&2
    echo "  Roll back with: $HERE/rollback.sh ${COMPONENT}" >&2
    exit 1
  fi
done

step "What is running now"
show_current

step "Keep the manifest honest"
cat <<EOF
  This script used 'kubectl set image', which does not edit any file. A 'kubectl apply -k
  overlays/demo' will therefore reset the cluster to whatever tag that overlay records.

  If this deploy is meant to stick, set ${MANIFEST_HINT}
  k8s/overlays/demo/kustomization.yaml to:

      $TAG

  and commit it. That file is the record of what this environment is supposed to be running, and
  smoke.sh compares the two.
EOF

step "Smoke"
CHAT_REPO="${CHAT_REPO:-$AGO_ROOT/ago-chat}" "$HERE/smoke.sh" "$DOMAIN"

# Migrations and rollback - the asymmetry, stated plainly because it is the part every rollback
# story gets silently wrong:
#
#   Rolling an image back does nothing whatsoever to the database. Schema only moves forward here;
#   `dotnet ef database update` has no counterpart in this script and deliberately none in
#   rollback.sh either.
#
# That is survivable only because every migration in this project so far has been additive, so code
# from an earlier commit runs unharmed against a later schema - it simply ignores columns it does not
# know about. That is a property to preserve on purpose, not luck: a migration must stay compatible
# with the image immediately before it (expand now, contract in a later release). A destructive
# change - dropping or renaming a column, narrowing a type - breaks rollback outright, and if one is
# ever merged, the recovery from a bad deploy stops being "roll the image back" and becomes
# "restore from backup" (15-02). Say so in that migration's own review, before it merges.
