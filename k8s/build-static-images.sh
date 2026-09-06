#!/usr/bin/env bash
# Builds the four static-bundle images the demo overlay's console/demo-shop1/demo-shop2/landing
# Services need (k8s/overlays/demo/console-static.yaml, demo-shop1-static.yaml,
# demo-shop2-static.yaml, landing-static.yaml) - ago-console's Vite SPA, two copies of ago-widget's
# built widget bundle, each paired with a different embedded demo page (`DEMO_PAGE_DIR` build arg -
# the bundle itself is identical between the two; only the HTML differs), and ago-landing's own
# single static HTML file (no build step at all).
#
# Deliberately a separate script from build-images.sh, not folded into it (8-02's own backlog
# item: "a different mechanism from 8-01's backend redeploy, documented separately" -
# runbooks/public-deploy.md has the full "how"): these are frontend static bundles behind nginx,
# not Ago.Chat.* .NET hosts, each with its own Dockerfile living in its own repository
# (ago-console/Dockerfile, ago-widget/Dockerfile, ago-landing/Dockerfile) rather than this shared
# script's own --build-context/--build-arg dance for a single shared Dockerfile the way
# build-images.sh works.
#
# Two callers, the same shape build-images.sh already has (`15-07`/`adr/0051`):
#
#   - The local loop, or anyone who just wants the images in their own Docker daemon. Defaults
#     produce `ago-console:local` and friends, exactly as before this item.
#   - The demo node, when a build has to happen there rather than being pulled from GHCR - a hotfix,
#     or a cluster rebuilt before CI has published. Set IMAGE_REPO and IMAGE_TAG=commit and it
#     produces exactly the names each repository's CI would have pushed, so the manifests do not
#     care which route the bytes took. Building on the node is now the exception, not the mechanism.
#
# `22-06`: ago-calendar-console left the set again. Its screens are part of ago-console now and its
# repository holds no Dockerfile any more, so a build_image call for it does not fail informatively -
# it fails at `docker build` with a missing file, in the middle of a redeploy, after the .NET images
# have already been built. Removed here rather than left to discover.
#
# `20-26`: ago-calendar-console joined the set. It needed no new mechanism - it is one more static
# nginx bundle behind a name, exactly the shape the other four already are, so it is one more
# CALENDAR_CONSOLE_REPO variable and one more build_image call, not a second script. Same reasoning
# deploy.sh's own FRONTENDS array gives for adding "calendar-console" there at `20-25`.
#
# Environment:
#   CONSOLE_REPO           path to the ago-console checkout           (default: ../../ago-console)
#   WIDGET_REPO            path to the ago-widget checkout            (default: ../../ago-widget)
#   LANDING_REPO           path to the ago-landing checkout           (default: ../../ago-landing)
#   IMAGE_REPO             registry/owner prefix, no trailing slash   (default: empty - bare local names)
#   IMAGE_TAG              `local`, `commit`, or an explicit tag      (default: local)
#
# IMAGE_TAG=commit is this script's one genuine difference from build-images.sh, and it exists
# because the difference is real: build-images.sh builds three images out of *one* repository, so
# one SHA names all three. These four come out of *three* repositories that move independently, and
# a single tag applied to all four would be a lie about at least two of them. `commit` therefore
# means "each image is tagged with its own repository's HEAD", not "all four share a tag". An
# explicit IMAGE_TAG still applies to everything, for the rare case where that is what you meant.
#
# NOTE what this script deliberately does NOT pass: any environment configuration. AGO_API_BASE_URL
# used to be set here and is not any more. Each Dockerfile carries the demo deployment's own values
# as committed defaults, so an image is a function of its commit alone - which is the only thing
# that lets a SHA tag be a truthful name for it (adr/0051). If this script fed a value in, an image
# built here and an image built by CI could differ under one tag, and the identity 15-06 bought
# would be spent on the way back out.
set -euo pipefail

CONSOLE_REPO="${CONSOLE_REPO:-../../ago-console}"
WIDGET_REPO="${WIDGET_REPO:-../../ago-widget}"
LANDING_REPO="${LANDING_REPO:-../../ago-landing}"
IMAGE_REPO="${IMAGE_REPO:-}"
# `local` stays the default so nothing outside the demo node changes - there a mutable tag costs
# nothing. It is the demo node where a mutable tag cost a day of a stale console bundle.
IMAGE_TAG="${IMAGE_TAG:-local}"

# The commit baked into the served files (each Dockerfile writes /version.json from it, and
# ago-widget additionally bakes it into the bundle as window.AgoChat.commit). Read from the
# checkout, never from IMAGE_TAG, so that even an image tagged `local` can name its own commit -
# the tag may be a convenience, the artifact should not be.
commit_of() { git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown; }

# A dirty tree produces an image labelled with a commit whose source does not match it. Loud, not
# fatal: building uncommitted work to try it is legitimate, believing the label afterwards is not.
warn_if_dirty() {
  if ! git -C "$1" diff --quiet HEAD 2>/dev/null; then
    echo "WARNING: $1 has uncommitted changes - its commit will not describe what is in the image." >&2
  fi
}

# name, source repo, then any extra `docker build` arguments (only ago-widget uses them).
build_image() {
  local name="$1" src="$2"; shift 2
  local commit tag image
  commit="$(commit_of "$src")"
  case "$IMAGE_TAG" in
    commit) tag="$commit" ;;
    *)      tag="$IMAGE_TAG" ;;
  esac
  image="${IMAGE_REPO:+${IMAGE_REPO}/}${name}:${tag}"
  echo "Building ${image} from ${src} (commit ${commit:0:7})..."
  docker build --build-arg "GIT_COMMIT=${commit}" "$@" -t "$image" "$src"
}

for repo in "$CONSOLE_REPO" "$WIDGET_REPO" "$LANDING_REPO"; do warn_if_dirty "$repo"; done

build_image ago-console          "$CONSOLE_REPO"
build_image ago-demo-shop1       "$WIDGET_REPO"
build_image ago-demo-shop2       "$WIDGET_REPO" --build-arg DEMO_PAGE_DIR=public-demo-2
build_image ago-landing          "$LANDING_REPO"
