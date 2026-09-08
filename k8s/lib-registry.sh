#!/usr/bin/env bash
# Ask a public GHCR repository whether it already holds a tag. Sourced, never executed.
#
# `23-109`. The premise this exists to correct was believed for days and never checked: `23-98`
# recorded that the migrator images were "built locally, never pushed, so unrecoverable once evicted",
# and that is **false for anything CI publishes**. Both backend repositories push their migrator on
# every commit to `main` (`for n in api worker webhooks migrator` in each CI workflow), the packages
# are public - no pod in this deployment carries an `imagePullSecrets` - and `imagePullPolicy: Never`
# was removed everywhere by `15-06`. So an evicted image whose tag is in the registry is re-pulled by
# the kubelet with nobody doing anything.
#
# Checked rather than reasoned: `ago-chat-migrator` has 101 tags in GHCR and an arbitrary one resolves
# with HTTP 200 to an anonymous caller.
#
# **What is genuinely at risk is only what this node builds and nothing else has**: `redeploy.sh` tags
# from the node's own checkout, so a commit whose CI run failed, or has not finished, produces images
# that exist here and nowhere else. That window is what the callers of this file close, by pulling
# what the registry already has and building only what it lacks.
#
# WHY AN ANONYMOUS TOKEN AND NOT `docker manifest inspect`. The node holds no registry credentials at
# all - it never needed any, because the packages are public - and `docker manifest inspect` against
# an unauthenticated daemon is inconsistent about whether it will try. Asking the registry's own token
# endpoint is explicit, needs nothing configured, and fails visibly rather than silently.

# registry_has <repo-path> <tag>   e.g. registry_has golyakoff/ago-chat-migrator <sha>
# Returns 0 when the tag resolves, 1 when it does not, and 2 when the question could not be asked at
# all - a caller must treat 2 as "build it", never as "it is there".
registry_has() {
  local repo="$1" tag="$2" token code

  token="$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [ -n "$token" ] || return 2

  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" 2>/dev/null)"

  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    # Anything else - a 5xx, a rate limit, an empty body because the network is down - is "cannot
    # tell". Returning 1 here would be a lie in the safe direction and returning 0 would be a lie in
    # the dangerous one, so it is its own answer.
    *)   return 2 ;;
  esac
}
