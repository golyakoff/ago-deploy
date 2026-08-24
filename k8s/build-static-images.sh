#!/usr/bin/env bash
# Builds the three static-bundle images the demo overlay's console/demo-shop1/demo-shop2 Services
# need (k8s/overlays/demo/console-static.yaml, demo-shop1-static.yaml, demo-shop2-static.yaml) -
# ago-console's Vite SPA and two copies of ago-widget's built widget bundle, each paired with a
# different embedded demo page (`DEMO_PAGE_DIR` build arg - the bundle itself is identical between
# the two; only the HTML differs).
#
# Deliberately a separate script from build-images.sh, not folded into it (8-02's own backlog
# item: "a different mechanism from 8-01's backend redeploy, documented separately" -
# runbooks/public-deploy.md has the full "how"): these are frontend static bundles behind nginx,
# not Ago.Chat.* .NET hosts, each with its own Dockerfile living in its own repository
# (ago-console/Dockerfile, ago-widget/Dockerfile) rather than this shared script's own
# --build-context/--build-arg dance for a single shared Dockerfile the way build-images.sh works.
# Same adr/0026 "no registry" delivery mechanism underneath either way: build straight into the
# local image store, `k3s ctr images import` picks it up from there (see this repository's own
# runbook for that step - not repeated here).
set -euo pipefail

CONSOLE_REPO="${CONSOLE_REPO:-../../ago-console}"
WIDGET_REPO="${WIDGET_REPO:-../../ago-widget}"
# The public API origin both widget bundles talk to (build.mjs bakes this in at build time,
# AGO_API_BASE_URL) - both demo tenants share the same API host, only the site key (baked into
# each demo page's own `data-site` attribute, not this build arg) tells them apart.
AGO_API_BASE_URL="${AGO_API_BASE_URL:-https://chat.reserve-me.ru}"

echo "Building ago-console:local from ${CONSOLE_REPO}..."
docker build -t ago-console:local "$CONSOLE_REPO"

echo "Building ago-demo-shop1:local from ${WIDGET_REPO} (AGO_API_BASE_URL=${AGO_API_BASE_URL})..."
docker build --build-arg "AGO_API_BASE_URL=${AGO_API_BASE_URL}" -t ago-demo-shop1:local "$WIDGET_REPO"

echo "Building ago-demo-shop2:local from ${WIDGET_REPO} (AGO_API_BASE_URL=${AGO_API_BASE_URL})..."
docker build --build-arg "AGO_API_BASE_URL=${AGO_API_BASE_URL}" --build-arg DEMO_PAGE_DIR=public-demo-2 \
  -t ago-demo-shop2:local "$WIDGET_REPO"
