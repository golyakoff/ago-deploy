#!/usr/bin/env bash
# Smoke test for a deployed AGO Chat environment.
#
# This checks the things that have actually broken, not a generic list. Every check below exists
# because something it would have caught did happen:
#
#   - 2026-08-25: the API was redeployed from a checkout six commits ahead of the database schema.
#     Three migrations were unapplied, so every query loading a Site failed and the widget was dead -
#     while every page still returned 200, because nginx was serving files perfectly well. A page
#     check alone is why this went unnoticed; `visitor-sessions` is what catches it.
#   - 2026-08-25: the console served a stale bundle for a day - shipped code and deployed code drift
#     silently while the image tag stays `:local` (ago-root's `15-06`). The backend half of that is
#     closed: the API now reports the commit it was built from and this script checks it. The four
#     static bundles still carry `:local` and still cannot, which is why that check is not here yet.
#   - 2026-08-25: Grafana was taken off the public edge; a re-apply of an old manifest would put it
#     back without anyone noticing.
#
# Run from anywhere for the HTTP checks. The migration check needs cluster access and is skipped with
# a warning without it - run it on the node to get the check that matters most.
#
# Usage:  ./smoke.sh [domain]           (default: reserve-me.ru)
#         CHAT_REPO=~/ago/ago-chat ./smoke.sh    (enables the migration check)
#
# Side effect worth knowing: the visitor-session check creates one real visitor row per run. Visitors
# are cheap and unreferenced ones age out, but a smoke test is not free of consequence and pretending
# otherwise is how a "harmless" check becomes a data problem somewhere else.

set -uo pipefail

DOMAIN="${1:-reserve-me.ru}"
PUBLIC_KEY="${PUBLIC_KEY:-demo_site}"
CHAT_REPO="${CHAT_REPO:-}"
NS="${NS:-ago-chat}"

pass=0; fail=0
ok()   { printf "  \033[32mPASS\033[0m  %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; fail=$((fail+1)); }
skip() { printf "  \033[33mSKIP\033[0m  %s\n" "$1"; }

code() { curl -s --max-time 20 -o /dev/null -w "%{http_code}" "$1"; }

echo "Smoke test against ${DOMAIN}"
echo

echo "Schema"
if [ -n "$CHAT_REPO" ] && command -v kubectl >/dev/null 2>&1; then
  applied=$(kubectl exec -n "$NS" deployment/postgres -- \
    psql -U ago -d ago_chat -t -A -c 'select "MigrationId" from "__EFMigrationsHistory";' 2>/dev/null | sort)
  ondisk=$(ls "$CHAT_REPO"/src/Ago.Chat.Infrastructure.Postgres/Migrations/*.cs 2>/dev/null \
    | grep -v Designer | grep -v ModelSnapshot | sed 's|.*/||;s|\.cs$||' | sort)
  if [ -z "$applied" ] || [ -z "$ondisk" ]; then
    bad "could not compare migrations (no database answer, or no migrations found in $CHAT_REPO)"
  else
    pending=$(comm -13 <(echo "$applied") <(echo "$ondisk"))
    if [ -z "$pending" ]; then ok "every migration in the checkout is applied"
    else bad "unapplied migrations - the code will fail on any query touching them:"; echo "$pending" | sed 's/^/          /'; fi
  fi
else
  skip "migration check (set CHAT_REPO and run where kubectl reaches the cluster)"
fi

echo
echo "API"
c=$(code "https://chat.${DOMAIN}/healthz/ready")
[ "$c" = "200" ] && ok "healthz/ready 200 (Postgres, RabbitMQ, Redis all answered)" || bad "healthz/ready returned $c"

# 15-06: the check that would have caught the 2026-08-25 stale deploy. The commit comes out of the
# compiled binary (BuildInfoResponse / -p:SourceRevisionId), not out of a manifest, so this says what
# is running rather than what was asked for.
version=$(curl -s --max-time 20 "https://chat.${DOMAIN}/healthz/version")
commit=$(echo "$version" | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p')
if [ -z "$commit" ]; then
  bad "healthz/version answered nothing usable - a pre-15-06 image is deployed, and it cannot name its own commit"
elif [ "$commit" = "unknown" ]; then
  bad "healthz/version reports commit=unknown - built without GIT_COMMIT, so this deploy is unidentifiable"
else
  ok "API reports commit ${commit:0:7} (built from a known source tree)"
  tag=$(kubectl get deployment ago-chat-api -n "$NS" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
  if [ -z "$tag" ]; then
    skip "image-tag comparison (needs cluster access)"
  elif [ "$tag" = "$commit" ]; then
    ok "the image tag matches the commit inside the binary"
  else
    bad "image tag ${tag:0:12} but the binary reports ${commit:0:12} - the tag is lying about its contents"
  fi
fi

session=$(curl -s --max-time 20 -w '\n%{http_code}' -X POST "https://chat.${DOMAIN}/api/v1/visitor-sessions" \
  -H 'Content-Type: application/json' -d "{\"publicKey\":\"${PUBLIC_KEY}\"}")
scode=$(echo "$session" | tail -1)
token=$(echo "$session" | head -1 | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
if [ "$scode" = "201" ] && [ -n "$token" ]; then
  ok "visitor-sessions 201 with a usable token (a Site loaded, so the schema matches the code)"
  n=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
    "https://chat.${DOMAIN}/hubs/visitor/negotiate?negotiateVersion=1" -H "Authorization: Bearer ${token}")
  [ "$n" = "200" ] && ok "visitor hub negotiates with that token" || bad "hub negotiate returned $n"
else
  bad "visitor-sessions returned $scode - this is the check that catches an unapplied migration"
  skip "hub negotiate (no token to try)"
fi

echo
echo "Frontends"
css=$(curl -s --max-time 20 "https://console.${DOMAIN}/" | grep -oE '/assets/index-[^"]+\.css' | head -1)
if [ -n "$css" ]; then
  body=$(curl -s --max-time 20 "https://console.${DOMAIN}${css}")
  if echo "$body" | grep -q -- '--ago-'; then ok "console serves the design system (its tokens are present)"
  else bad "console CSS carries no --ago- token - a pre-11-05 bundle is deployed"; fi
else
  bad "could not find the console's stylesheet"
fi
w=$(curl -s --max-time 20 "https://demo-shop1.${DOMAIN}/ago-chat.js")
echo "$w" | grep -qi configureLogging \
  && ok "widget bundle carries the 5-14 logging fix" \
  || bad "widget bundle predates 5-14 - it will print access tokens to the browser console"

echo
echo "Edge"
for h in "chat" "auth" "console" "demo-shop1" "demo-shop2"; do
  c=$(code "https://${h}.${DOMAIN}/")
  # auth's root redirects; anything that is not a connection failure means the listener is alive.
  [ "$c" != "000" ] && ok "${h}.${DOMAIN} answers ($c)" || bad "${h}.${DOMAIN} did not answer"
done
c=$(code "https://${DOMAIN}/")
[ "$c" = "200" ] && ok "apex answers 200" || bad "apex returned $c"
c=$(code "https://grafana.${DOMAIN}/")
[ "$c" = "000" ] && ok "grafana is not publicly served (as intended since 2026-08-25)" \
                 || bad "grafana answered $c - it is public again"

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
