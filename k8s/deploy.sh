#!/usr/bin/env bash
# Deploy a specific, identifiable build to the demo cluster.
#
#   ./deploy.sh <commit-sha>            the three Ago.Chat.* hosts, together
#   ./deploy.sh calendar <commit-sha>   the two Ago.Calendar.* hosts, together
#   ./deploy.sh <frontend> <commit-sha> one frontend: console | demo-shop1 | demo-shop2 | landing |
#                                       calendar-console
#   ./deploy.sh --current               print what is running and stop
#
# One commit argument for the hosts because all three are built from one repository, and one
# frontend at a time because the four (now five) are built from repositories that move independently -
# `15-07`. A single tag applied to all seven (now nine) would be a lie about at least two of them.
#
# `20-25`: AGO Calendar gets its own named component, "calendar", rather than being folded into the
# bare no-argument form above. `ago-chat` and `ago-calendar` are different repositories with different
# release cadences - the same reason a frontend is never rolled with the bare form - so a single commit
# SHA cannot honestly name a build of both. `ago-calendar-console` needed no new mechanism at all: it
# is one static bundle addressed by name, which is exactly what FRONTENDS already models, so it is one
# more entry in that array rather than a second array.
#
# `15-06`/`adr/0047`. Before this existed, a deploy meant rebuilding on the node under the mutable
# tag `:local` - so there was no earlier artifact to go back to, and nothing about a running pod
# said which commit was in it. On 2026-08-25 that cost twice in one day: a console bundle a week
# stale, and no way to tell. redeploy.sh made the sequence repeatable; it could not make it
# identifiable, because identity is a property of the artifact, not of the procedure.
#
# What this script deliberately is NOT: it does not build or pull the checkouts. It moves the cluster
# to an already-published artifact. redeploy.sh is still the build-from-source path.
#
# `8-08`: it does not run migrations either, and since that item it no longer needs to warn about the
# consequence. The hosts refuse to start against a schema older than the migrations they were compiled
# with, so moving to an image whose migrations have not been applied produces pods that visibly do not
# come up rather than pods that serve 200s for pages whose queries fail. If that happens, run
# Ago.Chat.Migrator at the same SHA (redeploy.sh step 5 is the worked form) and the pods recover on
# their own. Read the "Migrations and rollback" note at the bottom of this file before rolling
# anything back, because that asymmetry is the part usually got wrong.
set -euo pipefail

NS="${NS:-ago-chat}"
DOMAIN="${DOMAIN:-reserve-me.ru}"
REGISTRY="${REGISTRY:-ghcr.io/golyakoff}"
AGO_ROOT="${AGO_ROOT:-$HOME/ago}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same probe redeploy.sh uses: a `kubectl` on the PATH is not proof it can reach the cluster, since
# k3s keeps its kubeconfig root-only and a wrapper that forgets sudo passes `command -v` happily.
kc() { if kubectl version >/dev/null 2>&1; then kubectl "$@"; else sudo k3s kubectl "$@"; fi; }
step() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

# deployment:container - `kubectl set image` addresses the container by name, not by position.
HOSTS=("ago-chat-api:api" "ago-chat-worker:worker" "ago-chat-webhooks:webhooks")

# `20-25`: AGO Calendar's own running hosts - api and worker, not three. `ago-calendar-migrator` is a
# Job (base/calendar-migrator.yaml), never a Deployment, so it is not a `kubectl set image` target here
# any more than `ago-chat-migrator` is one in HOSTS above - moving it is redeploy.sh's job, not this
# script's (see the closing "Migrations and rollback" note at the bottom of this file: this script has
# never run migrations for either product). Kept as its own array rather than appended to HOSTS for the
# reason above the FRONTENDS array gives - it is a different repository's commit, so a bare SHA cannot
# honestly move both.
CALENDAR_HOSTS=("ago-calendar-api:api" "ago-calendar-worker:worker")

# `15-07`: name-as-typed:deployment. The container name equals the Deployment name for all five
# (overlays/demo/*-static.yaml), so one field is enough here where the hosts needed two.
# `22-06`: `calendar-console` stays in this table on purpose, even though its screens moved into
# ago-console and `redeploy.sh` no longer builds or rolls it. The Deployment is still running and
# still serving, until `22-09` retires the workload, its route, its certificate SAN and its DNS
# record in that strict order. This script operates on images that already exist, by SHA, so it is
# the one way left to move that workload while it exists - removing the entry now would take away
# the ability to operate something that is still deployed.
#
# `20-25`: `calendar-console` added - the identical shape as the other four, one static nginx bundle
# behind a name, so it needed a new array entry and nothing else.
FRONTENDS=("console:ago-console" "demo-shop1:ago-demo-shop1" "demo-shop2:ago-demo-shop2" "landing:ago-landing" "calendar-console:ago-calendar-console")

# The commit a running pod reports about itself, asked over the API server's own pod proxy. Two
# shapes, one idea:
#
#   - the .NET hosts serve GET /healthz/version on 8080, out of the compiled assembly. They are
#     Chiseled images - no shell, no curl, nothing to `kubectl exec` - so the proxy is not a
#     convenience here, it is the only way to ask without starting a helper pod that would itself
#     need an image pulled from somewhere.
#   - the four frontends serve /version.json on 80, written into the image at build time (15-07).
#     A browser bundle has no process to interrogate, so the artifact has to carry the answer as a
#     file. Same question, same parsing, one column below.
pod_commit() {
  local app="$1" port="$2" path="$3" pod
  pod="$(kc get pod -n "$NS" -l "app=$app" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -z "$pod" ] && { echo unreadable; return; }
  kc get --raw "/api/v1/namespaces/${NS}/pods/${pod}:${port}/proxy/${path}" 2>/dev/null \
    | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' | head -1 | grep . || echo unreadable
}

show_row() {
  local d="$1" commit="$2" tag
  tag="$(kc get deployment "$d" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  # The tag is a label somebody chose; the commit comes out of the artifact. Printing both side by
  # side is the point - they agree until a tag is re-pushed or a manifest edited by hand, and the
  # first time they disagree is the day this pairing earns its place.
  printf "  %-20s %-42s %s\n" "$d" "${tag##*:}" "$commit"
}

show_current() {
  printf "  %-20s %-42s %s\n" DEPLOYMENT "IMAGE TAG (what was asked for)" "COMMIT (what is running)"
  for entry in "${HOSTS[@]}"; do
    d="${entry%%:*}"
    show_row "$d" "$(pod_commit "$d" 8080 healthz/version)"
  done
  # `20-25`: same call as the chat hosts above, and today it prints "unreadable" for both, for two
  # different reasons worth telling apart rather than treating as one blank column:
  #   - `ago-calendar-api` answers on 8080 but maps no `/healthz/version` (confirmed against
  #     `Ago.Calendar.Api/Program.cs`; smoke.sh's own "Calendar API" section names the same gap and
  #     SKIPs the checks that would need it, `20-24`). The proxy call succeeds; there is nothing to
  #     parse a commit out of.
  #   - `ago-calendar-worker` binds no port at all - `Program.cs` uses the bare generic host, not
  #     `WebApplication` (confirmed against `base/calendar-worker.yaml`'s own header, which is explicit
  #     that this is unlike `ago-chat-worker`, which DOES sit in HOSTS above and DOES answer
  #     `/healthz/version` on a health-only Kestrel listener). The proxy call itself fails to connect.
  # Calling pod_commit identically for both anyway, rather than a special-cased blank column, is
  # deliberate: the day `Ago.Calendar.Api` gains `/healthz/version` (tracked outside this item, `20-24`
  # in flight in parallel with this one), its row starts reporting a real commit with no change needed
  # here. The worker's row has no equivalent day - it would need the same `WebApplication` change
  # `calendar-worker.yaml`'s header names as a gap, not merely a new route.
  for entry in "${CALENDAR_HOSTS[@]}"; do
    d="${entry%%:*}"
    show_row "$d" "$(pod_commit "$d" 8080 healthz/version)"
  done
  # `15-07`: the frontends are here for the same reason the hosts are, and it is not symmetry for
  # its own sake - the 2026-08-25 stale bundle was a *console*, so this half of the table is the
  # half that would have caught the incident this whole mechanism exists for.
  for entry in "${FRONTENDS[@]}"; do
    d="${entry##*:}"
    show_row "$d" "$(pod_commit "$d" 80 version.json)"
  done
}

if [ "${1:-}" = "--current" ]; then
  step "What is running now"
  show_current
  exit 0
fi

usage() {
  echo "usage: $0 <commit-sha> | $0 calendar <commit-sha> |" >&2
  echo "       $0 <console|demo-shop1|demo-shop2|landing|calendar-console> <commit-sha> | $0 --current" >&2
  exit 2
}

# One argument means the three chat hosts (unchanged from 15-06). Two means either the named
# "calendar" group (`20-25`) or a single frontend - checked in that order because "calendar" is not a
# FRONTENDS entry (it moves two Deployments, not one) and must not fall through to "unknown component".
COMPONENT=""
DEPLOYMENT=""
if [ "$#" -eq 2 ]; then
  COMPONENT="$1"; TAG="$2"
  if [ "$COMPONENT" != "calendar" ]; then
    for entry in "${FRONTENDS[@]}"; do
      [ "${entry%%:*}" = "$COMPONENT" ] && DEPLOYMENT="${entry##*:}"
    done
    if [ -z "$DEPLOYMENT" ]; then
      echo "unknown component '$COMPONENT'." >&2
      usage
    fi
  fi
elif [ "$#" -eq 1 ]; then
  TAG="$1"
else
  usage
fi

# A tag that cannot name a commit cannot be rolled back to, which is the whole reason this script
# exists - so refuse one here rather than discovering it during an incident. `main` and `latest` are
# rejected by the same rule, deliberately: both are moving targets that describe a moment, not a
# build.
if ! printf '%s' "$TAG" | grep -qE '^[0-9a-f]{40}$'; then
  echo "refusing '$TAG': the tag must be a full 40-character commit SHA (adr/0047)." >&2
  echo "  Every repository's CI publishes exactly that on every push to main; 'main' and 'latest'" >&2
  echo "  move and therefore cannot be deployed or rolled back to." >&2
  exit 2
fi

# The set of Deployments this invocation moves, and the image name each takes. The two paths differ
# only in what goes in these two arrays, so everything below - rollout waiting, failure handling,
# the manifest reminder, smoke - is written once (`15-07`).
TARGETS=()   # deployment names
IMAGES=()    # deployment=image, for `kubectl set image`
if [ "$COMPONENT" = "calendar" ]; then
  for entry in "${CALENDAR_HOSTS[@]}"; do
    d="${entry%%:*}"; c="${entry##*:}"
    TARGETS+=("$d")
    IMAGES+=("${c}=${REGISTRY}/${d}:${TAG}")
  done
  DESCRIPTION="${REGISTRY}/ago-calendar-{api,worker}:${TAG}"
  # `8-08`'s coupling stated here for the same reason it is stated in deploy.sh's chat path below:
  # this command never touches `ago-calendar-migrator` (a Job, not a Deployment - see CALENDAR_HOSTS's
  # own comment above), so nothing enforces by construction that the migrator's pinned tag moves with
  # it. The reminder names both.
  MANIFEST_HINT="both ago-calendar-* newTag values (api, worker - and ago-calendar-migrator's, to hold 8-08's coupling) in"
elif [ -n "$COMPONENT" ]; then
  TARGETS=("$DEPLOYMENT")
  IMAGES=("$DEPLOYMENT=${REGISTRY}/${DEPLOYMENT}:${TAG}")
  DESCRIPTION="${REGISTRY}/${DEPLOYMENT}:${TAG}"
  MANIFEST_HINT="the newTag for ${DEPLOYMENT} in"
else
  for entry in "${HOSTS[@]}"; do
    d="${entry%%:*}"; c="${entry##*:}"
    TARGETS+=("$d")
    IMAGES+=("${c}=${REGISTRY}/${d}:${TAG}")
  done
  DESCRIPTION="${REGISTRY}/ago-chat-{api,worker,webhooks}:${TAG}"
  MANIFEST_HINT="all three ago-chat-* newTag values in"
fi

step "Deploying $TAG"
show_current
echo
echo "  -> ${DESCRIPTION}"

step "Setting images"
for i in "${!TARGETS[@]}"; do
  kc set image "deployment/${TARGETS[$i]}" "${IMAGES[$i]}" -n "$NS"
done

# The API first and on its own, matching redeploy.sh's own ordering note: the console calls the API,
# so an API that is behind is the failure mode worth avoiding. Here all three move together, so the
# ordering only decides which failure surfaces first - and the API is the one worth learning about
# first, because it is the one a rollback has to save.
step "Waiting for rollouts"
for d in "${TARGETS[@]}"; do
  # A pull failure (wrong tag, package still private) never terminates the old pod: the rolling
  # update simply stalls with maxUnavailable respected, so service continues while this times out.
  # That is the safety property worth knowing - a broken *image reference* cannot take the site
  # down, whereas a broken *application* can, and only the second one needs a rollback.
  if ! kc rollout status "deployment/$d" -n "$NS" --timeout=180s; then
    echo
    echo "  $d did not become ready. The previous ReplicaSet is still serving." >&2
    kc get pods -n "$NS" -l "app=$d" >&2
    echo "  Roll back with: $HERE/rollback.sh ${COMPONENT}" >&2
    exit 1
  fi
done

step "What is running now"
show_current

step "Keep the manifest honest"
cat <<EOF
  This script used 'kubectl set image', which does not edit any file. A 'kubectl apply -k
  overlays/demo' will therefore reset the cluster to whatever tag that overlay records.

  If this deploy is meant to stick, set ${MANIFEST_HINT}
  k8s/overlays/demo/kustomization.yaml to:

      $TAG

  and commit it. That file is the record of what this environment is supposed to be running, and
  smoke.sh compares the two.
EOF

step "Smoke"
CHAT_REPO="${CHAT_REPO:-$AGO_ROOT/ago-chat}" "$HERE/smoke.sh" "$DOMAIN"

# Migrations and rollback - the asymmetry, stated plainly because it is the part every rollback
# story gets silently wrong:
#
#   Rolling an image back does nothing whatsoever to the database. Schema only moves forward here;
#   Ago.Chat.Migrator (`8-08`) has no reverse and deliberately none in rollback.sh either - it offers
#   no `--down` and no `--target`, because EF's generated `Down()` methods have never been executed in
#   this project and a rollback path nobody has tested is worse than none (`adr/0056`).
#
#   The guard the hosts now carry does not change this, and is worth understanding precisely: it
#   refuses when the database is *behind* the image, and says nothing when the database is *ahead*.
#   An image rolled back onto a newer schema starts normally, which is exactly what the expand/contract
#   discipline below is there to make safe.
#
# That was survivable for as long as every migration was additive, so code from an earlier commit ran
# unharmed against a later schema - it simply ignored columns it did not know about. That is a
# property to preserve on purpose, not luck: a migration must stay compatible with the image
# immediately before it (expand now, contract in a later release). A destructive change - dropping or
# renaming a column, narrowing a type - breaks rollback outright, and when one is merged, the recovery
# from a bad deploy stops being "roll the image back" and becomes "restore from backup" (15-02). Say
# so in that migration's own review, before it merges.
#
# One such migration has now merged, so the paragraph above is history rather than a live guarantee:
#
#   20260901213751_Stage15RepartitionMessagesByTenantHash (`15-09`/`adr/0087`) rebuilds `messages`
#   outright - `RENAME TO messages_pre_hash_partitioning`, `CREATE TABLE messages ... PARTITION BY
#   HASH (site_id)`, copy, `DROP TABLE`. The primary key becomes `(id, site_id)`, `site_id` becomes
#   `NOT NULL`, and the monthly `RANGE (created_at)` grid ceases to exist. It was taken deliberately,
#   with no live clients and no data to lose, which is the cheapest that change was ever going to be.
#
#   What this costs: **an ago-chat image from before that commit must not be rolled onto this schema.**
#   The host's own guard will not stop it - the database is *ahead* of such an image, which is the
#   direction the guard says nothing about. The old worker still carries `PartitionMaintenanceJob`,
#   which would try to add a monthly `RANGE` partition to a table that is now partitioned by hash.
#   Across this boundary the recovery from a bad deploy is restore-from-backup (15-02), not a rollback.
#   Rolling back *within* the post-15-09 range is unaffected.
#
# `20-25`: AGO Calendar - `ago_calendar` is a separate database on the same Postgres instance
# (`AGO_CALENDAR_CONNECTION_STRING`, calendar-migrator.yaml), but it inherits the identical asymmetry,
# by identical construction: confirmed directly against `Ago.Calendar.Migrator/Program.cs` at the
# pinned commit - "there is deliberately no --down and no --target: EF generates Down() methods and
# this project has never executed one" - the same sentence `adr/0056` wrote for `Ago.Chat.Migrator`.
# This script has never touched the calendar migrator in either direction (it moves Deployments; the
# migrator is a Job).
#
# UNLIKE THE PARAGRAPH ABOVE, this is not "no boundary migration is known" - checked, not assumed, and
# the answer is not clean: `20260901115524_Stage20AddWorkerScheduleAndRemoveCalendarBuffer` (`20-14`)
# drops `calendars.buffer_minutes` after backfilling it into the new `worker_schedules` table it
# creates - a genuinely destructive change, the same shape as `15-09` above. What makes it a non-issue
# *today*, checked rather than assumed: `ee3b38a` (this overlay's current pin) is the commit that made
# `ago-calendar` "buildable, migratable and publishable" at all (`20-20`) - the first image this product
# ever had, already carrying all eleven migrations including this one. There is no earlier calendar
# image anywhere in this cluster's revision history to roll back to, so `./rollback.sh calendar` (bare,
# undo-one-revision) cannot cross this boundary yet - there is nothing behind it. That stops being true
# the moment a second calendar commit is deployed: `./rollback.sh calendar <sha>` accepts any SHA, not
# only ones this cluster has run, and a SHA from before `ee3b38a` would cross it. If a further
# destructive AGO Calendar migration is ever written, name it here the same way - this file is where an
# operator reads the boundary before rolling anything back.
#
# **What this script does NOT close, stated rather than left implicit: nothing anywhere runs the
# calendar migrator Job at all yet.** redeploy.sh's step 5 applies `ago-chat-migrator`; it has no
# equivalent step for `ago-calendar-migrator` (grep it - the string does not appear in that script).
# 8-08's "the migrator's image moves with the hosts and never independently" is upheld today only by a
# convention documented in kustomization.yaml's own comment (all three calendar images are bumped
# together, by hand, in one commit) - there is no script enforcing it by construction the way
# redeploy.sh's `sed` substitution does for ago-chat. That is a real gap and a different one from what
# this item closes; see this item's own report.
