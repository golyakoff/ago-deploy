#!/usr/bin/env bash
# Builds the four Ago.Chat.* host images straight into the local Docker daemon's image store.
#
# `8-08`: Ago.Chat.Migrator joined the list. It is built from the same Dockerfile and tagged the same
# way as the other three deliberately - it applies the migrations *that commit* carries, so a
# migrator built from a different SHA than the hosts is the exact mismatch that item exists to
# prevent. There is no way to build three of the four here.
#
# Two callers, deliberately one script:
#
#   - The Docker Desktop cluster loop (runbooks/k8s-local.md). Defaults produce `ago-chat-api:local`
#     and friends, which is what overlays/local expects; its imagePullPolicy: Never turns "forgot to
#     build" into a clear ErrImageNeverPull instead of a hang against a registry that never had the tag.
#   - The demo node, when a build has to happen there rather than being pulled from GHCR (adr/0047) -
#     a hotfix, or a cluster rebuilt before CI has published. Set IMAGE_REPO and IMAGE_TAG and it
#     produces exactly the names CI would have pushed, so the manifests do not care which route the
#     bytes took.
#
# Environment:
#   CHAT_REPO   path to the ago-chat checkout            (default: ../../ago-chat)
#   NUGET_FEED  folder holding the Ago.Platform.* .nupkg (default: ../../.nuget-feed)
#   IMAGE_REPO  registry/owner prefix, no trailing slash (default: empty - bare local names)
#   IMAGE_TAG   tag to apply                             (default: local)
set -euo pipefail

CHAT_REPO="${CHAT_REPO:-../../ago-chat}"
NUGET_FEED="${NUGET_FEED:-../../.nuget-feed}"
IMAGE_REPO="${IMAGE_REPO:-}"
# `local` stays the default so the Docker Desktop loop and overlays/local are untouched by 15-06 -
# there, a mutable tag costs nothing, because the cluster and the source tree are the same machine.
# It is the *demo node* where a mutable tag cost a day of a stale bundle, and there IMAGE_TAG is the
# commit SHA, passed explicitly by deploy.sh.
IMAGE_TAG="${IMAGE_TAG:-local}"

# The commit baked into the binary (Dockerfile: -p:SourceRevisionId) and into the OCI labels. Read
# from the checkout, never from IMAGE_TAG, so that even an image tagged `local` produces a binary
# that can name its own commit at GET /healthz/version - the tag may be a convenience, the binary
# should not be. This is the half of 15-06 that a registry alone would not have fixed.
GIT_COMMIT="$(git -C "$CHAT_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"

# A dirty tree produces an image labelled with a commit whose source does not match it. Loud, not
# fatal: building uncommitted work to try it is legitimate, believing the label afterwards is not.
if ! git -C "$CHAT_REPO" diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: $CHAT_REPO has uncommitted changes - ${GIT_COMMIT:0:7} will not describe what is in this image." >&2
fi

# `22-27`: the backfill joins the list so its image exists wherever the hosts' images do. It is a
# one-shot corrective rather than a serving workload, so it gets no Deployment and is not in the
# overlay - `backfill-job.yaml` beside this script is applied by hand when it is needed. Building
# it here anyway is the cheap half: `22-26` found the image could not be built at all, and the
# reason nobody noticed is that nothing built it.
for project in Ago.Chat.Api Ago.Chat.Worker Ago.Chat.Webhooks Ago.Chat.Migrator Ago.Chat.RoleAssignmentBackfill; do
  name="$(echo "$project" | sed 's/Ago\.Chat\.//' | tr '[:upper:]' '[:lower:]')"
  image="${IMAGE_REPO:+${IMAGE_REPO}/}ago-chat-${name}:${IMAGE_TAG}"
  echo "Building ${image} from ${project} (commit ${GIT_COMMIT:0:7})..."
  docker build \
    --build-context "nugetfeed=${NUGET_FEED}" \
    --build-arg "PROJECT_NAME=${project}" \
    --build-arg "GIT_COMMIT=${GIT_COMMIT}" \
    -t "$image" \
    "$CHAT_REPO"
done
