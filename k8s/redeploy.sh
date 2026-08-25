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
API_BASE="${API_BASE:-https://chat.${DOMAIN}}"

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
         "$AGO_ROOT/ago-deploy/k8s/smoke.sh" 2>/dev/null || true

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
cd "$AGO_ROOT/ago-chat"
CHAT_REPO=. NUGET_FEED=../ago-deploy/.nuget-feed DOCKER_BUILDKIT=1 ../ago-deploy/k8s/build-images.sh
cd "$AGO_ROOT/ago-deploy/k8s"
CONSOLE_REPO=../../ago-console WIDGET_REPO=../../ago-widget AGO_API_BASE_URL="$API_BASE" \
  ./build-static-images.sh

step "4. Import into containerd"
# -n k8s.io is not optional: k3s's embedded containerd keeps kubelet-visible images in that
# namespace, and an import without it lands somewhere the kubelet never looks.
for img in ago-chat-api ago-chat-worker ago-chat-webhooks ago-console ago-demo-shop1 ago-demo-shop2 ago-landing; do
  printf "   %-18s " "$img"
  docker save "${img}:local" | sudo k3s ctr -n k8s.io images import - >/dev/null && echo "imported"
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

step "6. Restart, backend first"
# The API before the frontends: 12-03's owner view calls 12-02's endpoint, and a console that is
# newer than the API it talks to shows a screen wired to something that does not exist yet.
kc rollout restart deployment/ago-chat-api deployment/ago-chat-worker deployment/ago-chat-webhooks -n "$NS"
for d in ago-chat-api ago-chat-worker ago-chat-webhooks; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "7. Restart frontends"
kc rollout restart deployment/ago-console deployment/ago-demo-shop1 deployment/ago-demo-shop2 deployment/ago-landing -n "$NS"
for d in ago-console ago-demo-shop1 ago-demo-shop2 ago-landing; do
  kc rollout status "deployment/$d" -n "$NS" --timeout=180s
done

step "8. Smoke"
sleep 5
CHAT_REPO="$AGO_ROOT/ago-chat" "$AGO_ROOT/ago-deploy/k8s/smoke.sh" "$DOMAIN"
