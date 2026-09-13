#!/usr/bin/env bash
# `23-90`: durable record of what a deploy actually rolled out, and the comparison that notices when
# it was never committed. Sourced, never executed - same contract as lib-registry.sh.
#
# WHY THIS EXISTS. `deploy.sh` and `redeploy.sh` both move images with `kubectl set image` alone and
# never edit `overlays/demo/kustomization.yaml`'s own `newTag` pins - `check-manifest-drift.sh`'s own
# header explains why that gap is deliberate and normalised away there (`adr/0144`). On 2026-09-07 two
# such moves happened back to back with no commit between them, and nothing said so: the drift check's
# own tag-normalisation is, correctly, blind to exactly that. `docs/backlog/23-90-*.md` names three
# readings of "when are tags meant to disagree, and when have they merely been left disagreeing" and
# settles on **reading B - "the next run"**: a deploy records what it actually rolled out somewhere
# durable, and the next deploy (or the next standalone drift-check run) reads that record back and
# says so if it disagrees with what is currently committed. That is what the two functions below do.
#
# WHY A CONFIGMAP, AND NOT THE OTHER TWO SHAPES THAT ITEM'S OWN "Reading A/C" discussion implied were
# on the table for HOW to persist reading B's record:
#   - **A file this script itself commits** - rejected the same way the item's own "Reading A"
#     discussion rejected a clock: it is a net addition of instability, not a fix. A script that
#     commits to a git repository on the operator's or the node's behalf needs credentials this
#     deployment tooling has never held, races a human editing the same file by hand (the documented,
#     expected next step after every deploy), and turns a read-only advisory check into something with
#     write access to history. None of that is needed to answer "did the last run's tags get
#     committed" - reading the manifest that is already there is enough.
#   - **An external key-value store** (Redis, etcd outside the one Kubernetes already runs, etc.) -
#     rejected as a new dependency this deployment does not otherwise need. Every script in this
#     directory already assumes a working `kubectl`/cluster access and nothing else; a ConfigMap uses
#     exactly that access and nothing more.
#   - **A ConfigMap** (chosen). Durable across a redeploy of this tooling itself (it lives in the
#     cluster, not in this checkout), requires no credential this deployment does not already hold,
#     and - not written via this overlay's own `configMapGenerator`, deliberately - is never touched by
#     `apply-demo.sh`'s plain `kubectl apply -k` (no `--prune`), so an apply cannot silently reset or
#     erase it the way it resets every image tag the overlay itself pins.
#
# WHAT IT DOES NOT DO. No clock, no threshold, no "how long has this been running" - the item's own
# "Answered" section rejects that shape (reading A) explicitly, for adding a second, flakier failure
# mode on top of the one reading B alone already closes. This file only ever compares two point-in-time
# values: the last thing recorded, and what is committed right now.
#
# CONTRACT WITH CALLERS. Every function below calls `kc` and, where it prints a banner, `step` -
# neither is defined here. Every script in this directory already defines both identically (the
# kubectl/`sudo k3s kubectl` probe wrapper, and the bold one-line banner helper) before it does
# anything else, and this file is always sourced after that point in every caller - `deploy.sh`,
# `redeploy.sh`, `check-manifest-drift.sh`. Bash functions are visible process-wide once defined, so
# nothing here redefines them; doing so would risk masking a caller's own version instead of reusing
# it, which is the one thing this file must never do to a caller already mid-rollout.
#
# THE CONFIGMAP ITSELF: `ago-deploy-record`, in the same namespace as everything else `deploy.sh`
# already targets (`$NS`, default `ago-chat` - both products and every frontend already share one
# namespace in this overlay). One key per image this overlay's `images:` transformer names (`ago-chat-
# api`, ..., `ago-calendar-migrator`) - the same twelve names `overlays/demo/kustomization.yaml`'s own
# `images:` block already uses under `name:`, which is also, by this repository's own existing
# convention (`check-manifest-drift.sh`'s sed-normalisation comment, `apply-demo.sh`'s own regex),
# identical to the Deployment name for every entry except the two migrators (Jobs, not Deployments,
# named the same as their own repository regardless). Each value is the 40-character commit SHA that
# was actually asked for and passed its rollout.

# record_write <ns> <key>=<value> [<key>=<value> ...]
# Merges the given entries into `ago-deploy-record` in <ns>, creating the ConfigMap on its first
# write. A merge (kubectl patch --type=merge), never a replace: `deploy.sh` routinely moves only one
# component per invocation (the three chat hosts, or 'calendar', or a single frontend), and a replace
# would blank out every other component's own last-known-good tag on every ordinary deploy.
#
# Keys and values here are always a Deployment/repository name ([a-z0-9-]+, this repository's own
# established alphabet - check-manifest-drift.sh's and apply-demo.sh's own comments on why the class
# must include digits) and a 40-character lowercase-hex commit SHA - `deploy.sh` already refuses
# anything else before this could ever be called, and `redeploy.sh`'s SHAs come straight from
# `git rev-parse HEAD`. Neither ever contains a `"`, so building the merge-patch JSON by string
# interpolation is safe without a JSON library on a node that has none.
record_write() {
  local ns="$1"; shift
  [ "$#" -gt 0 ] || return 0

  kc get configmap ago-deploy-record -n "$ns" >/dev/null 2>&1 \
    || kc create configmap ago-deploy-record -n "$ns" >/dev/null

  local kv key value entries="" first=1
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    [ "$first" = 1 ] || entries="${entries},"
    entries="${entries}\"${key}\":\"${value}\""
    first=0
  done

  kc patch configmap ago-deploy-record -n "$ns" --type=merge -p "{\"data\":{${entries}}}" >/dev/null

  # Informational only, on annotations rather than `data` - `record_check` below reads only `.data`,
  # so this can never feed back into the comparison and cannot become a clock in disguise. It exists
  # purely for `kubectl describe configmap ago-deploy-record -n <ns>` to answer "who wrote this, and
  # when" for a human debugging a gap, which is exactly the question this mechanism's own commit-prep
  # report leaves for the next real redeploy to check.
  kc annotate configmap ago-deploy-record -n "$ns" --overwrite \
    "ago-deploy/written-by=${0##*/}" "ago-deploy/written-at=$(date -u +%FT%TZ)" >/dev/null 2>&1 || true
}

# record_check <ns> <overlay-dir>
# Prints a report and returns 0 (PASS - the record and the committed manifest agree, or there is
# nothing recorded yet to disagree with), 1 (DRIFT - the last recorded rollout was never committed),
# or 2 (UNKNOWN - the record or the manifest could not be read) - the same three-state convention
# `check-manifest-drift.sh` already established (`15-24`), not a fourth state.
#
# Deliberately renders the overlay itself (`kc kustomize`, a pure client-side render - no cluster call)
# rather than reusing a caller's own already-rendered copy, even though `check-manifest-drift.sh` has
# one sitting in a temp file by the time it would call this: keeping this function self-contained and
# callable with only `<ns> <overlay-dir>` is worth one extra `kubectl kustomize` (fast, local, no
# network) per call, against three call sites that would otherwise each need to thread a rendered-
# manifest path or its content through a second parameter shape.
record_check() {
  local ns="$1" overlay_dir="$2"
  step "Deploy record vs the committed manifest"

  if ! kc get ns "$ns" >/dev/null 2>&1; then
    echo "   UNKNOWN - no cluster reached (NS=${ns})."
    return 2
  fi

  if ! kc get configmap ago-deploy-record -n "$ns" >/dev/null 2>&1; then
    echo "   nothing recorded yet (no ago-deploy-record ConfigMap in ${ns}) - first deploy since this"
    echo "   mechanism landed, or a cluster nothing has ever deployed to with it. Not a gap: there is"
    echo "   no prior recorded rollout to disagree with the manifest."
    return 0
  fi

  local recorded manifest mismatches
  # `-o go-template`, not this file's usual `-o jsonpath` (every other `kc get` call in this
  # directory uses jsonpath) - found live against a real ConfigMap, not assumed: kubectl's jsonpath
  # dialect has no two-variable `range $k,$v := ...` form for iterating a map with its keys (it
  # errors "unrecognized character in action: U+002C ','"; a single-variable `.data.*` range gives
  # values only, with no key alongside to print). Go's own `text/template`, which `-o go-template`
  # runs, supports exactly this map-iteration form and needs no tool beyond kubectl itself, so it is
  # the smallest change that gets a key *and* its value out of `.data` in one call. The `$k`/`$v`
  # inside the single-quoted template are Go-template variables kubectl itself binds and expands,
  # never this shell's own - shellcheck SC2016 would otherwise flag it as an unexpanded shell variable.
  # shellcheck disable=SC2016
  recorded="$(kc get configmap ago-deploy-record -n "$ns" \
    -o go-template='{{range $k, $v := .data}}{{$k}} {{$v}}{{"\n"}}{{end}}' 2>/dev/null | sort)"
  if [ -z "$recorded" ]; then
    echo "   UNKNOWN - ago-deploy-record exists in ${ns} but its own data could not be read."
    return 2
  fi

  # Same registry/repo/tag pattern `check-manifest-drift.sh` and `apply-demo.sh` already use
  # (`[a-z0-9-]+`, not `[a-z-]+` - ago-demo-shop1/2 carry a digit). One line per image this overlay
  # pins, `name value` to match `recorded` above - `join` below needs both sorted the same way.
  manifest="$(kc kustomize "$overlay_dir" 2>/dev/null \
    | grep -oE 'ghcr\.io/golyakoff/[a-z0-9-]+:[0-9a-f]{40}' \
    | sed -E 's#ghcr\.io/golyakoff/([a-z0-9-]+):([0-9a-f]{40})#\1 \2#' \
    | sort -u)"
  if [ -z "$manifest" ]; then
    echo "   UNKNOWN - 'kubectl kustomize ${overlay_dir}' rendered no image this check understands;" \
         "run it directly to see why."
    return 2
  fi

  # Only components both sides name - a key `record_write` has never written for (nothing deployed
  # through this mechanism yet) is silence, not a gap; see the header for why widening this to "the
  # manifest names it and the record does not" would be reading A's clock in a smaller disguise.
  mismatches="$(join <(printf '%s\n' "$recorded") <(printf '%s\n' "$manifest") \
    | awk '$2 != $3 { printf "     %-22s recorded %s, manifest still pins %s\n", $1, $2, $3 }')"

  if [ -n "$mismatches" ]; then
    echo "   DRIFT - the last recorded rollout was never committed to the manifest:"
    echo
    echo "$mismatches"
    echo
    echo "   Commit the newTag value(s) above in ${overlay_dir}/kustomization.yaml - deploy.sh's own" \
         "\"Keep the manifest honest\" note names the exact lines - before the next deploy runs, so" \
         "this does not compound the way it did on 2026-09-07 (\`23-90\`)."
    return 1
  fi

  echo "   PASS - every component the manifest and the last recorded rollout both name agree."
  return 0
}
