#!/usr/bin/env bash
# Redeploy the demo environment - both AGO Chat and AGO Calendar - from the checkouts on this node.
#
# This exists because `runbooks/public-deploy.md` is a record of the first bring-up, not a procedure:
# its steps are marked "done 2026-08-24", which reads as finished rather than as "run this every
# time". On 2026-08-25 a redeploy followed that document and skipped step 9, migrations, because a
# step marked done does not look like a step. Every query loading a Site then failed against a schema
# three migrations behind, and the widget was dead while every page still returned 200.
#
# A script rather than a list, for exactly that reason: a list can be read selectively.
#
# `20-26`: AGO Calendar joined this script. Until this item it built and rolled the three AGO Chat
# hosts and four frontends only - no calendar image was built, none imported, and
# `ago-calendar-migrator` never ran on this path, so `8-08`'s "the migrator's image moves with the
# hosts and never independently" was upheld for the calendar only by a comment in kustomization.yaml
# asking a human to remember. It is now upheld by this script's own construction, the same way it
# already was for AGO Chat.
#
# Run on the node, from anywhere:  ~/ago/ago-deploy/k8s/redeploy.sh
# Environment:
#   AGO_ROOT   parent directory holding the checkouts (default: ~/ago)
#   DOMAIN     domain for the smoke test at the end (default: reserve-me.ru)
#   SKIP_PULL  set to 1 to build what is already checked out instead of fetching

set -euo pipefail

AGO_ROOT="${AGO_ROOT:-$HOME/ago}"
DOMAIN="${DOMAIN:-reserve-me.ru}"
NS="${NS:-ago-chat}"
# 15-06/adr/0047: the same registry path CI publishes to, so an image built here and an image
# pulled from there are interchangeable by name.
REGISTRY="${REGISTRY:-ghcr.io/golyakoff}"

# A bare `kubectl` on the PATH is not proof that it works: k3s keeps its kubeconfig root-only, so a
# wrapper that forgets sudo passes `command -v` and then fails on every call. Prove it can reach the
# cluster before trusting it.
kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

step "1. Checkouts"
# `15-13`: PULLED_DIRS is the single list of checkouts this step brings to their tip, and it is also
# the list every `*_SHA=` read below (step 3) is checked against by read_sha() - the same array, not
# a second one that has to be kept in sync by hand. That is what closes the gap this item found:
# ago-landing's commit used to be read (LANDING_SHA, ~90 lines below where the pull loop used to end)
# from a checkout this loop never touched, so a build-from-source run tagged the image with whatever
# the box happened to be sitting on - and *tagged* it with that stale SHA, so smoke.sh's tag-vs-binary
# check agreed with itself while the content served was fourteen commits old. ago-landing joining this
# array is the one-word fix; read_sha() below is what stops the next component from repeating it by
# construction rather than by someone remembering to check both lists, which is exactly how this one
# survived - they sat roughly ninety lines apart with nothing relating them.
#
# ago-platform and ago-deploy are pulled here but read no `*_SHA=` from read_sha(): ago-platform is
# packed into the local NuGet feed by the version in its own CHANGELOG (step 2), never tagged as an
# image, and ago-deploy is the checkout this script itself is running from, pulling its own working
# tree mid-run rather than being read back out as a build input. Being pulled without being read is
# fine and expected; read_sha() only refuses the opposite - a directory read without being pulled,
# which is the actual failure mode.
PULLED_DIRS=(ago-platform ago-chat ago-console ago-widget ago-landing ago-calendar ago-calendar-console ago-deploy)
if [ "${SKIP_PULL:-0}" = "1" ]; then
  echo "   SKIP_PULL=1 - building what is already here"
else
  for d in "${PULLED_DIRS[@]}"; do
    cd "$AGO_ROOT/$d"
    before=$(git rev-parse --short HEAD)
    git fetch -q origin && git checkout -q main && git pull -q --ff-only origin main
    printf "   %-14s %s -> %s\n" "$d" "$before" "$(git rev-parse --short HEAD)"
  done
fi

# Every `*_SHA=` in step 3 goes through this rather than calling `git -C ... rev-parse HEAD` directly,
# so a directory added to the SHA reads without being added to PULLED_DIRS above fails the run instead
# of silently reading whatever the box happens to be sitting on - the exact shape of the ago-landing
# gap `15-13` closed. Checked against the array unconditionally, including when SKIP_PULL=1 skipped
# the actual pulling above: SKIP_PULL only changes whether step 1 fetches, never which directories are
# legitimate to read a commit from.
read_sha() {
  local dir="$1" candidate
  for candidate in "${PULLED_DIRS[@]}"; do
    if [ "$candidate" = "$dir" ]; then
      git -C "$AGO_ROOT/$dir" rev-parse HEAD
      return 0
    fi
  done
  echo "BUG: read_sha $dir - '$dir' is not in PULLED_DIRS (step 1), so its commit would be read from" >&2
  echo "     whatever this box happens to be sitting on instead of its pulled tip. Add '$dir' to" >&2
  echo "     PULLED_DIRS, or read its commit some other way deliberately and say so." >&2
  exit 1
}

# git does not preserve the executable bit on clone or through some pulls, and both build scripts
# lose it. This bit them during the first bring-up and again on 2026-08-25; restoring it every run
# costs nothing and removes a failure that looks like a permissions mystery.
chmod +x "$AGO_ROOT/ago-deploy/k8s/build-images.sh" "$AGO_ROOT/ago-deploy/k8s/build-static-images.sh" \
         "$AGO_ROOT/ago-deploy/k8s/build-calendar-images.sh" \
         "$AGO_ROOT/ago-deploy/k8s/smoke.sh" "$AGO_ROOT/ago-deploy/k8s/deploy.sh" \
         "$AGO_ROOT/ago-deploy/k8s/rollback.sh" \
         "$AGO_ROOT/ago-deploy/k8s/check-theme-tokens.sh" 2>/dev/null || true

# `11-07`: the Keycloak login theme carries a copy of ago-console's design tokens, because a
# ConfigMap has to stand on its own inside the cluster. This is the moment that copy can be checked
# against the source - both checkouts are at their tip and nothing has been built yet. It is a hard
# failure rather than a warning: the whole point of the item was that a silently-diverging second
# copy of a colour is the failure this project has already had elsewhere. Run
# `k8s/check-theme-tokens.sh --write` to regenerate, look at the diff, and commit it.
bash "$AGO_ROOT/ago-deploy/k8s/check-theme-tokens.sh"

step "2. Pack the platform into the local feed"
# ago-chat restores Ago.Platform.* from this file feed by version. A platform release bumps the
# version in its CHANGELOG and every consuming .csproj, so a redeploy that skips this step fails at
# image build with NU1102 "Unable to find package ... version (>= x)" - which is exactly how the
# first real run of this script ended. The runbook had this step; the script did not.
export PATH="$PATH:$HOME/.dotnet/tools"
cd "$AGO_ROOT/ago-platform"
# Parsed without a bracket regex on purpose: the line is `## [0.15.0] - 2026-08-25`, and stripping
# the punctuation is both shorter and immune to the escaping that quoting a regex through layers of
# shell keeps mangling.
PLATFORM_VERSION=$(grep -m1 '^## ' CHANGELOG.md | tr -d '#[]' | awk '{print $1}')
echo "   packing Ago.Platform.* $PLATFORM_VERSION"
dotnet pack Ago.Platform.slnx -c Release -o "$AGO_ROOT/ago-deploy/.nuget-feed" -p:Version="$PLATFORM_VERSION" >/dev/null

step "3. Build images"
# 15-06: the three .NET hosts are built under the commit they came from, with the registry name CI
# would have used, so the artifact is the same shape whichever route it took - and so a rollback has
# something to go back to. `15-07` gave the four static bundles the same treatment: IMAGE_TAG=commit
# means each one is tagged with *its own repository's* HEAD, because the four come out of three
# repositories that move independently and one tag would be a lie about at least two of them.
#
# Note what is no longer passed: AGO_API_BASE_URL. Each frontend Dockerfile carries the deployment's
# own value as a committed default, so an image is a function of its commit alone (adr/0051) - and an
# image built here is byte-comparable with the one CI publishes for the same commit.
CHAT_SHA="$(read_sha ago-chat)"
CONSOLE_SHA="$(read_sha ago-console)"
WIDGET_SHA="$(read_sha ago-widget)"
LANDING_SHA="$(read_sha ago-landing)"
# `20-26`: ago-calendar's three hosts move as one commit, same reasoning as CHAT_SHA above -
# `calendar-migrator.yaml` applies the migrations *this* commit's Domain carries, so the migrator must
# never be tagged from a different SHA than the two hosts it runs ahead of (`8-08`). The console is its
# own repository with its own cadence, same as CONSOLE_SHA/WIDGET_SHA/LANDING_SHA above.
CALENDAR_SHA="$(read_sha ago-calendar)"
CALENDAR_CONSOLE_SHA="$(read_sha ago-calendar-console)"
echo "   ago-chat at $CHAT_SHA"
echo "   ago-console at ${CONSOLE_SHA:0:7}, ago-widget at ${WIDGET_SHA:0:7}, ago-landing at ${LANDING_SHA:0:7}"
echo "   ago-calendar at $CALENDAR_SHA"
echo "   ago-calendar-console at ${CALENDAR_CONSOLE_SHA:0:7}"
cd "$AGO_ROOT/ago-chat"
CHAT_REPO=. NUGET_FEED=../ago-deploy/.nuget-feed DOCKER_BUILDKIT=1 \
  IMAGE_REPO="$REGISTRY" IMAGE_TAG="$CHAT_SHA" ../ago-deploy/k8s/build-images.sh
# `20-26`: same NuGet feed step 2 just packed - Ago.Platform.* is versioned, not per-product, so the
# one feed serves both Dockerfiles' `nugetfeed` build-context mount (confirmed identical between
# ago-chat/nuget.docker.config and ago-calendar/nuget.docker.config - the latter is a stated unchanged
# copy of the former). No second pack step needed.
cd "$AGO_ROOT/ago-calendar"
CALENDAR_REPO=. NUGET_FEED=../ago-deploy/.nuget-feed DOCKER_BUILDKIT=1 \
  IMAGE_REPO="$REGISTRY" IMAGE_TAG="$CALENDAR_SHA" ../ago-deploy/k8s/build-calendar-images.sh
cd "$AGO_ROOT/ago-deploy/k8s"
CONSOLE_REPO=../../ago-console WIDGET_REPO=../../ago-widget LANDING_REPO=../../ago-landing \
  CALENDAR_CONSOLE_REPO=../../ago-calendar-console \
  IMAGE_REPO="$REGISTRY" IMAGE_TAG=commit ./build-static-images.sh

step "4. Import into containerd"
# -n k8s.io is not optional: k3s's embedded containerd keeps kubelet-visible images in that
# namespace, and an import without it lands somewhere the kubelet never looks.
#
# Importing under the registry's own name is what lets imagePullPolicy: IfNotPresent (15-06 removed
# the Never patches) find these locally and never reach out: the kubelet matches on the full
# reference, so `ghcr.io/.../ago-chat-api:<sha>` present in containerd is used as-is. Building here
# is now the exception - a hotfix, or a rebuilt cluster ahead of CI - not the normal path.
for img in ago-chat-api ago-chat-worker ago-chat-webhooks ago-chat-migrator; do
  printf "   %-18s " "$img"
  docker save "${REGISTRY}/${img}:${CHAT_SHA}" | sudo k3s ctr -n k8s.io images import - >/dev/null && echo "imported"
done
# `20-26`: ago-calendar's three images, at CALENDAR_SHA rather than CHAT_SHA - a separate loop rather
# than one more entry in the loop above because the tag differs, not because the mechanism does.
for img in ago-calendar-api ago-calendar-worker ago-calendar-migrator; do
  printf "   %-18s " "$img"
  docker save "${REGISTRY}/${img}:${CALENDAR_SHA}" | sudo k3s ctr -n k8s.io images import - >/dev/null && echo "imported"
done
for entry in "ago-console:$CONSOLE_SHA" "ago-demo-shop1:$WIDGET_SHA" "ago-demo-shop2:$WIDGET_SHA" "ago-landing:$LANDING_SHA" "ago-calendar-console:$CALENDAR_CONSOLE_SHA"; do
  printf "   %-18s " "${entry%%:*}"
  docker save "${REGISTRY}/${entry}" | sudo k3s ctr -n k8s.io images import - >/dev/null && echo "imported"
done

# `8-08` / ago-root `adr/0056`: this step used to be `dotnet ef database update`, run from the checkout
# on this node against a port-forwarded Postgres, needing the dotnet SDK and a NuGet restore on a
# machine whose only other job is running containers. It is now the Ago.Chat.Migrator image, built from
# the same commit as the hosts, applied as a Job. In order of how much each part matters:
#
#   - The thing that migrates and the things that serve are built from one commit by one build, so they
#     cannot disagree about which migrations exist. The old step applied whatever the checkout happened
#     to hold, which is not necessarily what the images were built from.
#   - It also works where this script is not in the loop at all - a cluster rebuilt from scratch during
#     `15-02`'s restore drill runs the Job because the Job is in the manifest set.
#   - No SDK, no restore, no port-forward on the node.
#
# And the safety net underneath: the hosts refuse to start against a schema older than the migrations
# they were compiled with (SchemaVersionGuard), so skipping this step can no longer reproduce the
# 2026-08-25 failure. It produces a deploy that visibly does not come up, which is the whole point.
#
# Before the restart, deliberately, exactly as before: migrations here are additive by policy, so the
# currently running old code is unaffected by columns it does not know about, whereas new code meeting
# an old schema fails on every query that touches them. `adr/0056` adopts expand/contract so that stays
# true. The one migration that broke the policy on purpose (`15-09`/`adr/0087`, which rebuilt and
# repartitioned `messages`) makes forward deploys no harder - it only rules out rolling an ago-chat
# image back *across* it, which `rollback.sh` spells out.
#
# Deleted first because a Job's pod template is immutable - re-applying one whose image tag changed is
# rejected outright, and every deploy changes it. That delete is the reason this lives in the script
# rather than being left to `apply -k`, which handles the from-scratch case perfectly well on its own.
#
# `-l app=<job>` is what keeps this from applying the rest of the overlay: the rendered output holds
# every Deployment at the tag pinned in kustomization.yaml, and applying those here would undo step 6's
# own `set image` and trigger a second rollout of everything.
#
# It has to be the *rendered overlay* rather than base/migrator.yaml directly, because kustomize
# hash-suffixes the `infra-credentials` Secret this Job's envFrom names - applying the raw base file
# would point it at a Secret that does not exist. A standalone kustomization under k8s/ was tried and
# does not work either: kustomize refuses a `resources:` path outside its own root (the same
# anti-path-traversal restriction base/kustomization.yaml already documents for configMapGenerator).
#
# Caveat, stated because it was found rather than guessed and could not be verified from a dev
# machine: `kubectl apply` resolves an API mapping for every document it is handed *before* the
# selector narrows anything, so this line fails on a cluster missing cert-manager's CRDs. The demo
# node has them - the same overlay's Certificate/ClusterIssuer are applied on every deploy - so this
# is fine there and would not be on a bare cluster.
#
# `20-26`: lifted into a function rather than left as a copy-pasted block for ago-calendar-migrator.
# Everything above this point is a property of "a migrator Job applied from the rendered overlay,
# deleted first because its pod template is immutable" - true of any product's migrator, not of
# ago-chat's specifically - so the two near-identical blocks this item would otherwise have produced
# are one block called twice with the job name and image differing. `adr/0056`'s reasoning (one
# attempt, then a human) is named once here rather than restated per product for the same reason.
run_migrator() {
  local job="$1" image="$2"
  kc delete job "$job" -n "$NS" --ignore-not-found >/dev/null
  kc kustomize "$AGO_ROOT/ago-deploy/k8s/overlays/demo" \
    | sed "s#image: .*/${job}:.*#image: ${image}#" \
    | kc apply -n "$NS" -l "app=${job}" -f - >/dev/null

  echo "   waiting for ${job} to finish..."
  if ! kc wait --for=condition=complete "job/${job}" -n "$NS" --timeout=300s 2>/dev/null; then
    echo "   MIGRATION FAILED (${job}) - the deploy stops here, on purpose (adr/0056)." >&2
    kc logs "job/${job}" -n "$NS" >&2 || true
    exit 1
  fi
  # Printed, not swallowed: `8-08`'s Scope is explicit that a migration which runs silently is the same
  # operational problem as one that does not run. This is the line that says which ones were applied.
  kc logs "job/${job}" -n "$NS" | sed 's/^/   /'
}

step "5. Migrations"
# Both products' migrators, both before either product's hosts move (step 6) - not merely "each
# migrator before its own hosts", which `8-08` requires, but the strictly stronger "neither product's
# hosts move until both migrations have succeeded". That is a deliberate choice, not the minimum this
# item asks for: redeploy.sh already treats one run as moving the whole demo environment forward
# together (chat hosts and every frontend share one script, one `set -euo pipefail`), and splitting the
# two products' migrate/move pairs apart here would be a new asymmetry this script has never had,
# introduced for no benefit - nothing depends on ago-calendar's migration happening only after
# ago-chat's hosts are already rolled, or vice-versa. It also means a failure in *either* migrator
# leaves *both* products' hosts exactly where they were before this run - see the header note on what
# a half-built deploy must not do.
run_migrator ago-chat-migrator "${REGISTRY}/ago-chat-migrator:${CHAT_SHA}"
run_migrator ago-calendar-migrator "${REGISTRY}/ago-calendar-migrator:${CALENDAR_SHA}"

step "6. Move the backends onto this commit, backend first"
# The API before the frontends: 12-03's owner view calls 12-02's endpoint, and a console that is
# newer than the API it talks to shows a screen wired to something that does not exist yet.
#
# `set image`, not `rollout restart` (15-06). A restart was the only option while every image wore
# the same mutable `:local` tag - the manifest never changed, so only a restart re-read what that
# tag now pointed at. Now the tag *is* the commit, so the manifest changes and Kubernetes records a
# revision: which is precisely what makes `rollback.sh` have something to go back to.
for entry in ago-chat-api:api ago-chat-worker:worker ago-chat-webhooks:webhooks; do
  kc set image "deployment/${entry%%:*}" "${entry##*:}=${REGISTRY}/${entry%%:*}:${CHAT_SHA}" -n "$NS"
done
# `20-26`: ago-calendar's two Deployments, at CALENDAR_SHA - a separate loop rather than folded into
# the one above because the tag differs, exactly as step 3's build and step 4's import already are.
for entry in ago-calendar-api:api ago-calendar-worker:worker; do
  kc set image "deployment/${entry%%:*}" "${entry##*:}=${REGISTRY}/${entry%%:*}:${CALENDAR_SHA}" -n "$NS"
done
for d in ago-chat-api ago-chat-worker ago-chat-webhooks ago-calendar-api ago-calendar-worker; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "7. Move the frontends onto their own commits"
# `15-07`: `set image`, not `rollout restart`, for exactly the reason step 6 gives for the hosts - a
# restart re-reads a tag that has not changed and records nothing a rollback can return to. Five
# images, four commits now (`20-26` adds ago-calendar-console, its own repository's own commit),
# because these come out of four repositories that move independently.
for entry in "ago-console:$CONSOLE_SHA" "ago-demo-shop1:$WIDGET_SHA" "ago-demo-shop2:$WIDGET_SHA" "ago-landing:$LANDING_SHA" "ago-calendar-console:$CALENDAR_CONSOLE_SHA"; do
  d="${entry%%:*}"
  kc set image "deployment/$d" "${d}=${REGISTRY}/${entry}" -n "$NS"
done
for d in ago-console ago-demo-shop1 ago-demo-shop2 ago-landing ago-calendar-console; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "8. Smoke"
sleep 5
CHAT_REPO="$AGO_ROOT/ago-chat" "$AGO_ROOT/ago-deploy/k8s/smoke.sh" "$DOMAIN"

cat <<EOF

Deployed ago-chat $CHAT_SHA and ago-calendar $CALENDAR_SHA. To go back to whatever was running before
this:

    ./rollback.sh                 # the three chat hosts
    ./rollback.sh calendar        # the two calendar hosts, on their own

and to move to a build CI already published, without building anything here:

    ./deploy.sh <commit-sha>            # chat
    ./deploy.sh calendar <commit-sha>   # calendar

k8s/overlays/demo/kustomization.yaml still names older tags unless somebody updates it; a
'kubectl apply -k overlays/demo' would move the cluster back to them. If this deploy is meant to
stick, set these newTag values and commit (this list was previously missing the two migrators - '8-08'
applies to their tags exactly as much as to the hosts they run ahead of):

    ago-chat-{api,worker,webhooks,migrator}   $CHAT_SHA
    ago-console                               $CONSOLE_SHA
    ago-demo-shop{1,2}                        $WIDGET_SHA
    ago-landing                               $LANDING_SHA
    ago-calendar-{api,worker,migrator}        $CALENDAR_SHA
    ago-calendar-console                      $CALENDAR_CONSOLE_SHA
EOF
