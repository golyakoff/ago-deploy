#!/usr/bin/env bash
# Redeploy the AGO Chat demo environment from the checkouts on this node.
#
# This exists because `runbooks/public-deploy.md` is a record of the first bring-up, not a procedure:
# its steps are marked "done 2026-08-24", which reads as finished rather than as "run this every
# time". On 2026-08-25 a redeploy followed that document and skipped step 9, migrations, because a
# step marked done does not look like a step. Every query loading a Site then failed against a schema
# three migrations behind, and the widget was dead while every page still returned 200.
#
# A script rather than a list, for exactly that reason: a list can be read selectively.
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
if [ "${SKIP_PULL:-0}" = "1" ]; then
  echo "   SKIP_PULL=1 - building what is already here"
else
  for d in ago-platform ago-chat ago-console ago-widget ago-deploy; do
    cd "$AGO_ROOT/$d"
    before=$(git rev-parse --short HEAD)
    git fetch -q origin && git checkout -q main && git pull -q --ff-only origin main
    printf "   %-14s %s -> %s\n" "$d" "$before" "$(git rev-parse --short HEAD)"
  done
fi

# git does not preserve the executable bit on clone or through some pulls, and both build scripts
# lose it. This bit them during the first bring-up and again on 2026-08-25; restoring it every run
# costs nothing and removes a failure that looks like a permissions mystery.
chmod +x "$AGO_ROOT/ago-deploy/k8s/build-images.sh" "$AGO_ROOT/ago-deploy/k8s/build-static-images.sh" \
         "$AGO_ROOT/ago-deploy/k8s/smoke.sh" "$AGO_ROOT/ago-deploy/k8s/deploy.sh" \
         "$AGO_ROOT/ago-deploy/k8s/rollback.sh" 2>/dev/null || true

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
CHAT_SHA="$(git -C "$AGO_ROOT/ago-chat" rev-parse HEAD)"
CONSOLE_SHA="$(git -C "$AGO_ROOT/ago-console" rev-parse HEAD)"
WIDGET_SHA="$(git -C "$AGO_ROOT/ago-widget" rev-parse HEAD)"
LANDING_SHA="$(git -C "$AGO_ROOT/ago-landing" rev-parse HEAD)"
echo "   ago-chat at $CHAT_SHA"
echo "   ago-console at ${CONSOLE_SHA:0:7}, ago-widget at ${WIDGET_SHA:0:7}, ago-landing at ${LANDING_SHA:0:7}"
cd "$AGO_ROOT/ago-chat"
CHAT_REPO=. NUGET_FEED=../ago-deploy/.nuget-feed DOCKER_BUILDKIT=1 \
  IMAGE_REPO="$REGISTRY" IMAGE_TAG="$CHAT_SHA" ../ago-deploy/k8s/build-images.sh
cd "$AGO_ROOT/ago-deploy/k8s"
CONSOLE_REPO=../../ago-console WIDGET_REPO=../../ago-widget LANDING_REPO=../../ago-landing \
  IMAGE_REPO="$REGISTRY" IMAGE_TAG=commit ./build-static-images.sh

step "4. Import into containerd"
# -n k8s.io is not optional: k3s's embedded containerd keeps kubelet-visible images in that
# namespace, and an import without it lands somewhere the kubelet never looks.
#
# Importing under the registry's own name is what lets imagePullPolicy: IfNotPresent (15-06 removed
# the Never patches) find these locally and never reach out: the kubelet matches on the full
# reference, so `ghcr.io/.../ago-chat-api:<sha>` present in containerd is used as-is. Building here
# is now the exception - a hotfix, or a rebuilt cluster ahead of CI - not the normal path.
for img in ago-chat-api ago-chat-worker ago-chat-webhooks; do
  printf "   %-18s " "$img"
  docker save "${REGISTRY}/${img}:${CHAT_SHA}" | sudo k3s ctr -n k8s.io images import - >/dev/null && echo "imported"
done
for entry in "ago-console:$CONSOLE_SHA" "ago-demo-shop1:$WIDGET_SHA" "ago-demo-shop2:$WIDGET_SHA" "ago-landing:$LANDING_SHA"; do
  printf "   %-18s " "${entry%%:*}"
  docker save "${REGISTRY}/${entry}" | sudo k3s ctr -n k8s.io images import - >/dev/null && echo "imported"
done

step "5. Migrations"
# Before the restart, deliberately. Migrations here are additive, so the currently-running old code
# is unaffected by columns it does not know about - whereas new code meeting an old schema fails on
# every query that touches the new columns, which is the failure this whole script exists to prevent.
# A destructive migration would need a different order and its own thinking; there has not been one.
export PATH="$PATH:$HOME/.dotnet/tools"
cd "$AGO_ROOT/ago-chat"
dotnet restore src/Ago.Chat.Infrastructure.Postgres/Ago.Chat.Infrastructure.Postgres.csproj \
  --configfile /tmp/nuget.migrations.config >/dev/null
kc port-forward "svc/postgres" 15432:5432 -n "$NS" >/tmp/redeploy-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
sleep 4
# Ask the running Postgres which secret it actually uses rather than pattern-matching the namespace.
# kustomize hash-suffixes the name, so an edit to .env leaves the previous secret behind and a grep
# returns two - which is exactly what happened on the first real run of this script.
SECRET_NAME=$(kc get deployment postgres -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].secretRef.name}')
PGPW=$(kc get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
AGO_CHAT_CONNECTION_STRING="Host=localhost;Port=15432;Database=ago_chat;Username=ago;Password=${PGPW}" \
  dotnet ef database update -p src/Ago.Chat.Infrastructure.Postgres -s src/Ago.Chat.Infrastructure.Postgres
kill $PF 2>/dev/null || true; trap - EXIT

step "6. Move the backend onto this commit, backend first"
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
for d in ago-chat-api ago-chat-worker ago-chat-webhooks; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "7. Move the frontends onto their own commits"
# `15-07`: `set image`, not `rollout restart`, for exactly the reason step 6 gives for the hosts - a
# restart re-reads a tag that has not changed and records nothing a rollback can return to. Four
# images, three commits, because these come out of three repositories.
for entry in "ago-console:$CONSOLE_SHA" "ago-demo-shop1:$WIDGET_SHA" "ago-demo-shop2:$WIDGET_SHA" "ago-landing:$LANDING_SHA"; do
  d="${entry%%:*}"
  kc set image "deployment/$d" "${d}=${REGISTRY}/${entry}" -n "$NS"
done
for d in ago-console ago-demo-shop1 ago-demo-shop2 ago-landing; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "8. Smoke"
sleep 5
CHAT_REPO="$AGO_ROOT/ago-chat" "$AGO_ROOT/ago-deploy/k8s/smoke.sh" "$DOMAIN"

cat <<EOF

Deployed ago-chat $CHAT_SHA. To go back to whatever was running before this:

    ./rollback.sh

and to move to a build CI already published, without building anything here:

    ./deploy.sh <commit-sha>

k8s/overlays/demo/kustomization.yaml still names older tags unless somebody updates it; a
'kubectl apply -k overlays/demo' would move the cluster back to them. If this deploy is meant to
stick, set the seven newTag values and commit:

    ago-chat-{api,worker,webhooks}   $CHAT_SHA
    ago-console                      $CONSOLE_SHA
    ago-demo-shop{1,2}               $WIDGET_SHA
    ago-landing                      $LANDING_SHA
EOF
