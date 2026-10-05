#!/usr/bin/env bash
# Turn a UI test selection into xcodebuild scope, applying the floor and the
# fallback. The model proposes; this script disposes.
#
# Usage: decide-ui-tests.sh <selection.json> <conclusion>
#   selection.json  the structured_output from the select-ui-tests skill,
#                   possibly empty or malformed
#   conclusion      the action's conclusion output ("success" or anything else)
#
# Prints shell-style KEY=VALUE lines on stdout:
#   run_all=true|false
#   only_testing=<space-separated -only-testing flags, empty when run_all>
#   reason=<one line>
#   classes=<space-separated class names, empty when run_all>
#
# Rules, enforced here and not by the model:
#   - LaunchTests always runs.
#   - Anything other than a valid selection with run_all=false runs everything.
#   - Only names in ALLOWED can reach the command line. Unknown names are
#     dropped with a note; a dropped name never widens or narrows silently
#     because the allowlist is checked against the test target in CI.
set -euo pipefail

file="${1:?selection.json}"
conclusion="${2:-failure}"

ALLOWED="SearchFlowUITests FavoritesFlowUITests AccessibilityAuditUITests ScreenshotGalleryUITests LaunchTests"
FLOOR="LaunchTests"

run_all=true
reason=""
classes=""
flags=""

if [ "$conclusion" != "success" ]; then
  reason="selection did not complete (conclusion: $conclusion); running the full suite"
elif ! [ -s "$file" ] || ! jq -e 'type == "object" and (.classes | type == "array") and (.run_all | type == "boolean")' "$file" >/dev/null 2>&1; then
  reason="selection output was empty or malformed; running the full suite"
elif [ "$(jq -r '.run_all' "$file")" = "true" ]; then
  reason="$(jq -r '.summary // "selection asked for the full suite"' "$file")"
else
  run_all=false
  reason="$(jq -r '.summary // "selected from the diff"' "$file")"
  picked="$( { jq -r '.classes[]' "$file"; echo "$FLOOR"; } | sort -u )"
  for c in $picked; do
    case " $ALLOWED " in
      *" $c "*)
        classes="${classes:+$classes }$c"
        flags="${flags:+$flags }-only-testing:testExampleUITests/$c"
        ;;
      *) echo "ignoring unknown class '$c'" >&2 ;;
    esac
  done
fi

printf 'run_all=%s\n' "$run_all"
printf 'only_testing=%s\n' "$flags"
printf 'reason=%s\n' "$reason"
printf 'classes=%s\n' "$classes"
