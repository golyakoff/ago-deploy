#!/usr/bin/env bash
# Builds the three Ago.Calendar.* host images straight into the local Docker daemon's image store.
#
# `20-26`: this is build-images.sh's own shape, copied rather than folded into it - the same call
# build-static-images.sh's own header makes for staying separate from build-images.sh at `15-07`.
# build-images.sh's identity is written for one product: its env var is named CHAT_REPO, its project
# list assumes the "Ago.Chat." prefix, and it is the exact command docs/runbooks/k8s-local.md (which
# this item does not edit) names by that behaviour. Generalising it here would touch a script outside
# this item's own lane for the sake of one new caller. Three images, not four - `ago-calendar` ships
# no Webhooks-equivalent host (checked against src/: Api, Worker, Migrator, and four inner layers with
# no fourth deployable).
#
# Two callers, deliberately one script, matching build-images.sh's own reasoning:
#
#   - The Docker Desktop cluster loop, if/when overlays/local grows a calendar base (it does not yet -
#     checked, `grep -r calendar overlays/local` finds nothing). Defaults produce `ago-calendar-api:local`
#     and friends, the same shape overlays/local's imagePullPolicy: Never expects from build-images.sh.
#   - The demo node, when a build has to happen there rather than being pulled from GHCR - a hotfix, or
#     a cluster rebuilt before CI has published. Set IMAGE_REPO and IMAGE_TAG and it produces exactly
#     the names CI would have pushed - redeploy.sh is this script's caller for that path.
#
# Environment:
#   CALENDAR_REPO  path to the ago-calendar checkout          (default: ../../ago-calendar)
#   NUGET_FEED     folder holding the Ago.Platform.* .nupkg   (default: ../../.nuget-feed)
#   IMAGE_REPO     registry/owner prefix, no trailing slash   (default: empty - bare local names)
#   IMAGE_TAG      tag to apply                                (default: local)
set -euo pipefail

CALENDAR_REPO="${CALENDAR_REPO:-../../ago-calendar}"
NUGET_FEED="${NUGET_FEED:-../../.nuget-feed}"
IMAGE_REPO="${IMAGE_REPO:-}"
# `local` stays the default for the same reason build-images.sh's does - it is the demo node where a
# mutable tag has actually cost a day of staleness, not the local loop.
IMAGE_TAG="${IMAGE_TAG:-local}"

# The commit baked into the binary (Dockerfile: -p:SourceRevisionId) - read from the checkout, never
# from IMAGE_TAG, so an image tagged `local` still produces a binary that can name its own commit.
# `Ago.Calendar.Api` answers this at GET /healthz/version since `20-24`; `Ago.Calendar.Worker` has no
# HTTP surface to ask (deploy.sh's own pod_commit prints "unreadable" for it, correctly).
GIT_COMMIT="$(git -C "$CALENDAR_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"

# A dirty tree produces an image labelled with a commit whose source does not match it. Loud, not
# fatal: building uncommitted work to try it is legitimate, believing the label afterwards is not.
if ! git -C "$CALENDAR_REPO" diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: $CALENDAR_REPO has uncommitted changes - ${GIT_COMMIT:0:7} will not describe what is in this image." >&2
fi

for project in Ago.Calendar.Api Ago.Calendar.Worker Ago.Calendar.Migrator; do
  name="$(echo "$project" | sed 's/Ago\.Calendar\.//' | tr '[:upper:]' '[:lower:]')"
  image="${IMAGE_REPO:+${IMAGE_REPO}/}ago-calendar-${name}:${IMAGE_TAG}"
  echo "Building ${image} from ${project} (commit ${GIT_COMMIT:0:7})..."
  docker build \
    --build-context "nugetfeed=${NUGET_FEED}" \
    --build-arg "PROJECT_NAME=${project}" \
    --build-arg "GIT_COMMIT=${GIT_COMMIT}" \
    -t "$image" \
    "$CALENDAR_REPO"
done
