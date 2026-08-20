#!/usr/bin/env bash
# Builds the three host images the Docker Desktop Kubernetes cluster loop needs, straight into the
# local Docker daemon's image store - no registry involved (runbooks/k8s-local.md). Run this before
# `kubectl apply -k overlays/local` any time host source changes; the overlay's imagePullPolicy:
# Never means a stale or missing image fails fast (ErrImageNeverPull) instead of hanging.
set -euo pipefail

CHAT_REPO="${CHAT_REPO:-../../ago-chat}"
NUGET_FEED="${NUGET_FEED:-../../.nuget-feed}"

for project in Ago.Chat.Api Ago.Chat.Worker Ago.Chat.Webhooks; do
  tag="$(echo "$project" | sed 's/Ago\.Chat\.//' | tr '[:upper:]' '[:lower:]')"
  echo "Building ago-chat-${tag}:local from ${project}..."
  docker build \
    --build-context "nugetfeed=${NUGET_FEED}" \
    --build-arg "PROJECT_NAME=${project}" \
    -t "ago-chat-${tag}:local" \
    "$CHAT_REPO"
done
