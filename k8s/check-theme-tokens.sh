#!/usr/bin/env bash
# Keep the Keycloak login theme's design tokens identical to ago-console's, or fail loudly.
#
#   ./check-theme-tokens.sh            verify - exit 1 and print a diff if they have drifted
#   ./check-theme-tokens.sh --write    regenerate the block in ago.css from tokens.css
#
# `11-07` shipped the theme with the token values hand-copied out of
# ago-console/src/design/tokens.css, and said in its own commit message that a copy is not an
# acceptable answer: the item asks for the values to be generated, or vendored with a check that
# fails when they diverge. This is that check, and the generator behind it - the copy stays (the
# theme has to be a self-contained ConfigMap that a cluster can mount without ago-console anywhere
# near it), but it stops being a copy anyone maintains by remembering.
#
# What it does:
#   1. reads every `--ago-*` declaration out of ago-console/src/design/tokens.css (`11-05`, the
#      single source);
#   2. reads ago.css and collects every `var(--ago-*)` it actually uses *outside* the generated
#      block - so the block contains exactly the tokens the stylesheet needs, and an unused one
#      disappears the next time it is regenerated rather than lingering as a second, stale copy;
#   3. rebuilds the block and compares. Any difference - a changed value in tokens.css, an edit to
#      the block by hand, a token used here that tokens.css does not declare - is drift, and drift
#      exits non-zero.
#
# Where it runs: `redeploy.sh` calls it right after it pulls the checkouts, which is the moment the
# two repositories are both at their tip and a divergence is about to be baked into a ConfigMap.
# There is no CI in this repository to hang it on (`adr/0015`'s pipelines are the two backend repos
# only), and that is worth stating rather than implying: outside a redeploy, this check runs when a
# person or a script runs it.
#
# Environment:
#   AGO_CONSOLE   path to the ago-console checkout (default: a sibling of this repository, which is
#                 both the documented workspace layout and the node's own ~/ago layout)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_CSS="$HERE/base/keycloak-theme/ago.css"
AGO_CONSOLE="${AGO_CONSOLE:-$(cd "$HERE/../.." && pwd)/ago-console}"
TOKENS_CSS="$AGO_CONSOLE/src/design/tokens.css"

MODE="check"
case "${1:-}" in
  --write) MODE="write" ;;
  ""|--check) ;;
  *) echo "usage: $(basename "$0") [--check|--write]" >&2; exit 2 ;;
esac

if [ ! -f "$TOKENS_CSS" ]; then
  echo "check-theme-tokens: cannot find ago-console's tokens at $TOKENS_CSS" >&2
  echo "  set AGO_CONSOLE to the checkout, e.g. AGO_CONSOLE=~/ago/ago-console $0" >&2
  exit 2
fi

generated="$(mktemp)"
trap 'rm -f "$generated"' EXIT

awk -v TOKENS="$TOKENS_CSS" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

  BEGIN {
    # tokens.css, in declaration order - the block is emitted in the source order so a reviewer can
    # read the two files side by side.
    while ((getline line < TOKENS) > 0) {
      if (line ~ /^[ \t]*--ago-[A-Za-z0-9-]+:/) {
        name = line; sub(/:.*/, "", name); name = trim(name)
        value = line; sub(/^[ \t]*--ago-[A-Za-z0-9-]+:[ \t]*/, "", value)
        sub(/;[ \t]*(\/\*.*)?$/, "", value)
        tval[name] = trim(value)
        torder[++tn] = name
      }
    }
    close(TOKENS)
    if (tn == 0) { print "check-theme-tokens: no --ago-* declarations in " TOKENS > "/dev/stderr"; exit 3 }
  }

  { lines[++n] = $0 }
  /GEN-BEGIN/ { begin = n }
  /GEN-END/   { end = n }

  END {
    if (!begin || !end || end < begin) {
      print "check-theme-tokens: GEN-BEGIN/GEN-END markers missing from the theme stylesheet" > "/dev/stderr"
      exit 3
    }

    # Which tokens does the stylesheet actually use, outside the generated block?
    for (i = 1; i <= n; i++) {
      if (i >= begin && i <= end) continue
      rest = lines[i]
      while (match(rest, /var\(--ago-[A-Za-z0-9-]+/)) {
        used = substr(rest, RSTART + 4, RLENGTH - 4)
        rest = substr(rest, RSTART + RLENGTH)
        if (used in tval) { need[used] = 1; continue }
        # A `--ago-login-*` name is deliberately local to this theme - it exists because the login
        # page departs from the console on purpose, and the departure is checked separately below.
        if (used ~ /^--ago-login-/) { continue }
        print "check-theme-tokens: " used " is used by the theme but is not declared in tokens.css" > "/dev/stderr"
        exit 3
      }
    }

    for (i = 1; i <= begin; i++) print lines[i]
    print ":root {"
    for (i = 1; i <= tn; i++) if (torder[i] in need) printf "  %s: %s;\n", torder[i], tval[torder[i]]
    print "}"
    for (i = end; i <= n; i++) print lines[i]
  }
' "$THEME_CSS" > "$generated"

# The one deliberate departure, checked rather than trusted: the login page loads no webfont
# (`11-07`), so `--ago-login-font` is `--ago-font-sans` with the webfont families dropped. That
# makes it a *suffix* of the console's stack, and a suffix is checkable - if someone changes the
# system fallbacks in tokens.css, this stops being true and says so.
console_stack="$(sed -n 's/^[ \t]*--ago-font-sans:[ \t]*\(.*\);.*$/\1/p' "$TOKENS_CSS" | head -1)"
login_stack="$(sed -n 's/^[ \t]*--ago-login-font:[ \t]*\(.*\);.*$/\1/p' "$THEME_CSS" | head -1)"
if [ -z "$login_stack" ] || [ -z "$console_stack" ]; then
  echo "check-theme-tokens: could not read --ago-font-sans / --ago-login-font" >&2
  exit 3
fi
case "$console_stack" in
  *"$login_stack") ;;
  *)
    echo "check-theme-tokens: the login font stack is no longer the tail of the console's." >&2
    echo "  ago-console --ago-font-sans : $console_stack" >&2
    echo "  login theme --ago-login-font: $login_stack" >&2
    echo "  The login theme drops the webfont families on purpose and keeps the system tail." >&2
    exit 1
    ;;
esac

if [ "$MODE" = "write" ]; then
  if cmp -s "$generated" "$THEME_CSS"; then
    echo "check-theme-tokens: already in step with $TOKENS_CSS"
  else
    cat "$generated" > "$THEME_CSS"
    echo "check-theme-tokens: regenerated the token block in $THEME_CSS"
  fi
  exit 0
fi

if cmp -s "$generated" "$THEME_CSS"; then
  echo "check-theme-tokens: login theme tokens match $TOKENS_CSS"
  exit 0
fi

echo "check-theme-tokens: the login theme's tokens have drifted from ago-console's." >&2
echo "  source: $TOKENS_CSS" >&2
echo "  theme : $THEME_CSS" >&2
echo "  Run '$(basename "$0") --write' to regenerate, then look at the diff before committing it -" >&2
echo "  a token that changed for the console may or may not be right for a login page." >&2
diff -u "$THEME_CSS" "$generated" >&2 || true
exit 1
