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
#     silently while the image tag stays `:local` (ago-root's `15-06`). Both halves are closed now:
#     the API reports the commit it was built from, and since `15-07` each of the four static
#     bundles serves the same answer at /version.json. The "Frontends" section below is that check,
#     and it is the one aimed squarely at the incident - which was a *console* bundle.
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

# The chat API's hostname, as a variable rather than spelled out six times. It moved from `chat.` to
# `chat-api.` on 2026-09-02, when the naming scheme was settled: the bare product name belongs to the
# human-facing console, and an API takes the `-api` suffix. `chat.` becomes the chat console at the
# end of that migration.
#
# **This check is the gate for that flip.** While both names still serve the API, a green run here
# means every consumer can be moved to `chat-api.` and verified before `chat.` changes meaning. If
# this is red, the flip is not safe yet - and it will be red until the DNS record exists and the
# certificate has been re-issued to cover it.
CHAT_API="chat-api.${DOMAIN}"
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
c=$(code "https://${CHAT_API}/healthz/ready")
[ "$c" = "200" ] && ok "healthz/ready 200 (Postgres, RabbitMQ, Redis all answered)" || bad "healthz/ready returned $c"

# 15-06: the check that would have caught the 2026-08-25 stale deploy. The commit comes out of the
# compiled binary (BuildInfoResponse / -p:SourceRevisionId), not out of a manifest, so this says what
# is running rather than what was asked for.
version=$(curl -s --max-time 20 "https://${CHAT_API}/healthz/version")
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

session=$(curl -s --max-time 20 -w '\n%{http_code}' -X POST "https://${CHAT_API}/api/v1/visitor-sessions" \
  -H 'Content-Type: application/json' -d "{\"publicKey\":\"${PUBLIC_KEY}\"}")
scode=$(echo "$session" | tail -1)
token=$(echo "$session" | head -1 | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
if [ "$scode" = "201" ] && [ -n "$token" ]; then
  ok "visitor-sessions 201 with a usable token (a Site loaded, so the schema matches the code)"
  n=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
    "https://${CHAT_API}/hubs/visitor/negotiate?negotiateVersion=1" -H "Authorization: Bearer ${token}")
  [ "$n" = "200" ] && ok "visitor hub negotiates with that token" || bad "hub negotiate returned $n"
else
  bad "visitor-sessions returned $scode - this is the check that catches an unapplied migration"
  skip "hub negotiate (no token to try)"
fi

echo
echo "Calendar API"
# `20-20`/`20-24`: the same checks every other host gets - answers, reports its commit, tag matches the
# binary, dependencies answer - now for real. `20-20` found `Ago.Calendar.Api` mapping no health route
# at all, only a bare `GET /` returning the loaded module's name, and SKIPped the commit/tag checks
# rather than faking them against a route with no commit information to compare. `20-24` closed that:
# `Program.cs` now maps `/healthz/live`, `/healthz/ready` and `/healthz/version` the same way
# `Ago.Chat.Api` does (`3-06`/`15-06`), so the two checks that used to SKIP below are real now.
# **This check used to hit `calendar.`, which is the console.** It was written before the naming
# settled (see this file's own note at the frontends list below) and never moved, so it asserted the
# API was up by fetching a static SPA - which answers 200 to everything, including while the API is
# in a restart loop. That is exactly what happened on `20-20`'s first deploy: `ago-calendar-api` was
# crash-looping on a 500 and this check would have passed.
#
# So it now hits `calendar-api.` and asserts the **body**, not the status. A status alone cannot tell
# an API apart from a static site; `Ago.Calendar` in the response body can only come from the API.
b=$(curl -s --max-time 20 "https://calendar-api.${DOMAIN}/")
case "$b" in
  *Ago.Calendar*) ok "calendar API answers (GET / returned its module name, the only route it maps)" ;;
  *)              bad "calendar API did not answer with its module name (got: $(printf '%s' "$b" | head -c 60))" ;;
esac

# The control that makes the line above mean something. A host that 200s every path would pass any
# single positive check; this one must 404. It is also what makes the dev-endpoint absence below
# readable - without it, a 404 there is indistinguishable from the whole host being unreachable.
c=$(code "https://calendar-api.${DOMAIN}/nonsense-control-path")
[ "$c" = "404" ] && ok "calendar API 404s an unmapped path (so it is a real API host, not a catch-all)" \
                 || bad "calendar API answered $c on a path that should not exist - a catch-all would make every check above meaningless"

# **The check that would have caught this deploy's actual defect.** `Operator__RequireHttpsMetadata`
# was unset, so JwtBearer refused the in-cluster `http://` authority and threw on every request that
# reached the authentication middleware - a 500, not a 401. A guarded route answering 401 proves the
# JWT handler constructed itself and then refused; 500 proves it could not construct at all, and 404
# would mean the route is not mapped. All three are distinguishable here, which is the point.
c=$(code "https://calendar-api.${DOMAIN}/api/v1/console/configuration")
[ "$c" = "401" ] && ok "calendar API refuses an unauthenticated console call with 401 (the JWT handler initialised)" \
                 || bad "calendar API answered $c, not 401, on a guarded route - 500 means the authentication handler cannot construct (check Operator__RequireHttpsMetadata against the authority scheme); 404 means the route is not mapped"

# `ago-root#354`: DevProvisioningEndpoints and PhoneVerificationDevEndpoints map only outside
# Production, and the manifests now state the environment rather than inheriting it. That gate is
# covered by a test in `ago-calendar`; this asserts it on the deployed thing, which is the only place
# the manifest and the binary meet. 404 here is meaningful only against the control above.
for p in "/dev/tenants" "/dev/phone-verifications/last-code"; do
  c=$(code "https://calendar-api.${DOMAIN}${p}")
  [ "$c" = "404" ] && ok "calendar dev endpoint ${p} is absent (404)" \
                   || bad "calendar dev endpoint ${p} answered $c - tenant provisioning is exposed in Production"
done

# The console is a separate host and gets its own check rather than standing in for the API.
c=$(code "https://calendar.${DOMAIN}/")
[ "$c" = "200" ] && ok "calendar console answers" \
                 || bad "calendar console did not answer (got $c)"

c=$(code "https://calendar-api.${DOMAIN}/healthz/ready")
[ "$c" = "200" ] && ok "calendar API healthz/ready 200 (Postgres, Redis both answered)" || bad "calendar API healthz/ready returned $c"

# `20-24`: the check that would have caught a stale or mismatched calendar image - `20-20`'s own gap,
# closed the same way `15-06` closed it for `Ago.Chat.Api`. The commit comes out of the compiled binary
# (`BuildInfoResponse` / `-p:SourceRevisionId`), not out of a manifest, so this says what is running
# rather than what was asked for.
version=$(curl -s --max-time 20 "https://calendar-api.${DOMAIN}/healthz/version")
commit=$(echo "$version" | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p')
if [ -z "$commit" ]; then
  bad "calendar API healthz/version answered nothing usable - a pre-20-24 image is deployed, and it cannot name its own commit"
elif [ "$commit" = "unknown" ]; then
  bad "calendar API healthz/version reports commit=unknown - built without GIT_COMMIT, so this deploy is unidentifiable"
else
  ok "calendar API reports commit ${commit:0:7} (built from a known source tree)"
  tag=$(kubectl get deployment ago-calendar-api -n "$NS" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
  if [ -z "$tag" ]; then
    skip "calendar API image-tag comparison (needs cluster access)"
  elif [ "$tag" = "$commit" ]; then
    ok "the calendar API image tag matches the commit inside the binary"
  else
    bad "calendar API image tag ${tag:0:12} but the binary reports ${commit:0:12} - the tag is lying about its contents"
  fi
fi

echo
echo "Operator hub"
# `5-18`: the check that would have caught the console never connecting - and the reason it does more
# than negotiate is that **negotiate succeeded the whole time it was broken**.
# `OperatorHub.OnConnectedAsync` aborted the connection immediately *after* a successful SignalR
# handshake, which is a clean close: nothing logged, no transport fallback, nothing registered in
# Redis, and a console that said "Offline". Any check that stops at negotiate is blind to it - which is
# what the visitor check above is, and why 12/12 stayed green through a total product outage.
#
# Server-Sent Events, not WebSockets: it is the transport that carries a real hub connection (the hub's
# OnConnectedAsync runs for it) while staying pure HTTP, so curl alone can see the difference. A healthy
# connection holds the stream open until this times out; an aborted one flushes the handshake ack and
# then SignalR's own close frame, `{"type":7}`, within a second. Both were measured against the live
# deployment before this was written.
#
# **The `Origin` header is the whole check.** Both origin validators allow a connection that sends none
# - a non-browser client has no cross-origin claim to verify - so without it this would pass vacuously
# against a deployment no browser can connect to.
#
# **A freshly minted tenant, not the seeded one, and that is not incidental.** The bug was invisible to
# the seeded tenants: somebody had added the console to *their* AllowedOrigins, so the old, wrong check
# happened to pass for them. Only a tenant whose origins are just its own shop page - which is every
# tenant `8-07` mints - showed it. A check built on the seeded credential would have stayed green.
mint=$(curl -s --max-time 20 -w '\n%{http_code}' -X POST "https://${CHAT_API}/api/v1/demo/credentials")
mcode=$(echo "$mint" | tail -1)
if [ "$mcode" != "200" ]; then
  skip "operator hub connection (demo minting answered ${mcode} - DemoTenant off, at capacity, or rate-limited)"
else
  muser=$(echo "$mint" | head -1 | grep -oE '"username":"[^"]+"' | cut -d'"' -f4)
  mpass=$(echo "$mint" | head -1 | grep -oE '"password":"[^"]+"' | cut -d'"' -f4)
  otok=$(curl -s --max-time 20 -X POST \
    "https://auth.${DOMAIN}/realms/ago-chat/protocol/openid-connect/token" \
    -d "client_id=ago-console" -d "grant_type=password" \
    --data-urlencode "username=${muser}" --data-urlencode "password=${mpass}" \
    | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)

  if [ -z "$otok" ]; then
    bad "the minted operator could not obtain a token - the credential 8-07 hands a stranger does not work"
  else
    ok "a minted operator signs in (the credential a stranger is given actually works)"
    # `adr/0091` step 3: the console lives at `chat.` now and `console.` is retired. This line is not
    # cosmetic - the Origin header *is* this check (see the paragraph above), so a stale value here
    # does not weaken the test, it inverts it: the hub correctly refuses a retired origin, and the
    # check reports that correct refusal as "no operator can hold a connection". It did exactly that
    # on the first run after the migration.
    OORIGIN="https://office.${DOMAIN}"
    octoken=$(curl -s --max-time 20 -X POST \
      "https://${CHAT_API}/hubs/operator/negotiate?negotiateVersion=1" \
      -H "Authorization: Bearer ${otok}" -H "Origin: ${OORIGIN}" \
      | grep -oE '"connectionToken":"[^"]+"' | cut -d'"' -f4)

    if [ -z "$octoken" ]; then
      bad "operator hub negotiate returned no connectionToken"
    else
      ok "operator hub negotiates"
      ossefile=$(mktemp)
      ( curl -s --max-time 6 -o "$ossefile" \
          "https://${CHAT_API}/hubs/operator?id=${octoken}" \
          -H "Authorization: Bearer ${otok}" -H "Origin: ${OORIGIN}" \
          -H 'Accept: text/event-stream' >/dev/null 2>&1 ) &
      osse=$!
      sleep 1
      curl -s --max-time 10 -o /dev/null -X POST \
        "https://${CHAT_API}/hubs/operator?id=${octoken}" \
        -H "Authorization: Bearer ${otok}" -H "Origin: ${OORIGIN}" \
        --data-binary "$(printf '{"protocol":"json","version":1}\036')"
      wait $osse 2>/dev/null || true

      if grep -q '"type":7' "$ossefile" 2>/dev/null; then
        bad "the operator hub accepted the handshake and then closed the connection - no operator can hold one, so nothing is ever assigned (5-18)"
      else
        ok "an operator holds a hub connection from the console's origin (5-18: the check that was missing)"
      fi
      rm -f "$ossefile"
    fi
  fi
fi

echo
echo "Frontends"
# `15-07`: the check that would have caught the 2026-08-25 stale *console* bundle, which is the
# incident all of this exists for. Every frontend image writes the commit it was built from into
# /version.json, so this asks the served origin itself rather than sniffing the bundle for a string
# that happens to have been added in some known release. The old checks did the latter - "does the
# CSS carry an --ago- token", "does the JS mention configureLogging" - and they could only ever
# catch drift older than one specific named change, never drift in general.
#
# url:deployment. The landing page is at the apex, not a subdomain. `20-20`: the calendar console added -
# it is served at `calendar.` (the bare product name is the human-facing console), and its own
# Dockerfile writes /version.json the identical way (adr/0051's pattern,
# copied rather than reinvented), so this loop needs no special case for it.
# `22-10`: `office.` is checked beside `chat.` deliberately - the same Deployment answers at both
# names for the length of the move, so seeing one commit twice is the point rather than
# redundancy. It is what proves the new listener and route reach the console, rather than
# reaching a 200 from somewhere.
for entry in "office.${DOMAIN}:ago-console" "demo-shop1.${DOMAIN}:ago-demo-shop1" \
             "demo-shop2.${DOMAIN}:ago-demo-shop2" "${DOMAIN}:ago-landing" \
             "calendar.${DOMAIN}:ago-calendar-console"; do
  host="${entry%%:*}"; deploy="${entry##*:}"
  commit=$(curl -s --max-time 20 "https://${host}/version.json" \
           | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$commit" ]; then
    bad "${host} serves no usable /version.json - a pre-15-07 bundle is deployed, and it cannot name its own commit"
    continue
  fi
  if [ "$commit" = "unknown" ]; then
    bad "${host} reports commit=unknown - built without GIT_COMMIT, so this deploy is unidentifiable"
    continue
  fi
  ok "${host} reports commit ${commit:0:7}"
  tag=$(kubectl get deployment "$deploy" -n "$NS" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
  if [ -z "$tag" ]; then
    skip "${host} image-tag comparison (needs cluster access)"
  elif [ "$tag" = "$commit" ]; then
    ok "${host}'s image tag matches the commit inside the bundle"
  else
    bad "${host} image tag ${tag:0:12} but the bundle reports ${commit:0:12} - the tag is lying about its contents"
  fi
done
# The widget bundle carries the same commit inside itself (window.AgoChat.commit), which is the copy
# that survives being embedded on a tenant's page where none of our files sit beside it. Checked
# against demo-shop1's own /version.json above, so a mismatch means the image was assembled from a
# bundle and a version.json that did not come from one build.
wcommit=$(curl -s --max-time 20 "https://demo-shop1.${DOMAIN}/version.json" \
          | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$wcommit" ] && [ "$wcommit" != "unknown" ]; then
  curl -s --max-time 20 "https://demo-shop1.${DOMAIN}/widget.js" | grep -q "$wcommit" \
    && ok "the widget bundle itself carries that same commit" \
    || bad "the widget bundle does not contain ${wcommit:0:12} - either a pre-15-07 bundle, or the bundle and the version.json beside it did not come from one build"
fi

# `adr/0092`/`#342`: the URL a real tenant's page actually loads the widget from. Checked separately
# from demo-shop1 above, because for a long time *only* the demo shops served a bundle at all - each
# image carries its own copy - while `chat.reserve-me.ru/widget.js`, the address `ago-landing` was
# handing out for people to paste, was a 404. Nobody noticed, because nothing asked. `#342` closed the
# other half of that gap: the file `ago-widget` actually builds is `widget.js` now too, not
# `ago-chat.js` - the internal product name no longer leaks into a tenant's HTML.
#
# Two assertions, and the second is the one that matters. A 200 alone proves nothing here: an SPA
# catch-all answers 200 for any path whatsoever, which is exactly how `console.reserve-me.ru/widget.js`
# looked healthy while serving `index.html` - a control request to a nonsense path returned the
# identical bytes. So the content type is checked too, and a control request to a nonsense path under
# the same prefix is checked against a real 404 - this image's nginx `try_files ... =404` (nginx.conf),
# not a catch-all, so a path nothing serves must actually 404 rather than fall through to something
# that happens to answer 200.
wct=$(curl -s -o /dev/null --max-time 20 -w '%{content_type}' "https://${CHAT_API}/widget/widget.js")
case "$wct" in
  *javascript*) ok "the widget is served at https://${CHAT_API}/widget/widget.js (${wct})" ;;
  *) bad "https://${CHAT_API}/widget/widget.js returned content-type '${wct}', not JavaScript - a tenant pasting the install snippet gets a script tag that does not load" ;;
esac
wnf=$(code "https://${CHAT_API}/widget/this-file-does-not-exist.js")
[ "$wnf" = "404" ] && ok "a nonsense path under /widget/ genuinely 404s (not an SPA catch-all in disguise)" \
                    || bad "a nonsense path under /widget/ returned $wnf, not 404 - the content-type check above could be passing vacuously"
# The booking module has to be a sibling: ui/moduleLoader.ts resolves it relative to the widget's own
# <script src> (adr/0058), so an origin serving widget.js without it breaks booking at runtime and
# only for the tenants who enabled it - the quietest possible failure.
bct=$(curl -s -o /dev/null --max-time 20 -w '%{content_type}' "https://${CHAT_API}/widget/widget-module-booking.js")
case "$bct" in
  *javascript*) ok "the booking module is served beside it" ;;
  *) bad "https://${CHAT_API}/widget/widget-module-booking.js returned '${bct}' - booking would fail at runtime for tenants who enabled it" ;;
esac

echo
echo "Edge"
# Both names of each API are listed while the rename is in flight. `chat.` and `console.` both still
# answer today - `chat.` serves the API and becomes the console at the end of it, `console.` is
# deleted after that. `calendar-console` is gone from this list because that name was never created:
# the scheme settled on `calendar.` for the console and `calendar-api.` for the API before anything
# was deployed under the first proposal.
# `22-10`: `office.` joins while `chat.` is still here. Both answer for the length of the move,
# and `chat.` leaves this list in the same change that removes it from the route, the listener
# and the SAN - in that order, with the A-record last of all.
for h in "office" "chat-api" "auth" "demo-shop1" "demo-shop2" "calendar" "calendar-api"; do
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
