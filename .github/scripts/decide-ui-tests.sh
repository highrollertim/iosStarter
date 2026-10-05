#!/usr/bin/env bash
# Turn a UI test selection into xcodebuild scope, applying the floor and the
# fallback. The model proposes; this script disposes.
#
# Usage: decide-ui-tests.sh <selection.json> <conclusion>
#   selection.json  the structured_output from the select-ui-tests skill,
#                   possibly empty or malformed
#   conclusion      the action's conclusion output ("success" or anything else)
#
# Prints KEY=VALUE lines on stdout, one per line, no key repeated:
#   run_all=true|false
#   only_testing=<space-separated -only-testing flags, empty when run_all>
#   classes=<space-separated class names, empty when run_all>
#   reason=<one line, model-authored, control characters stripped, capped>
#
# Rules, enforced here and not by the model:
#   - LaunchTests always runs.
#   - Anything other than a valid selection with run_all=false runs everything.
#   - Only names in ALLOWED can reach the command line. Unknown names are
#     dropped with a note.
#   - `reason` is the only model-authored value printed. It is reduced to one
#     line of at most 300 printable characters so it cannot carry a second
#     KEY=VALUE line, and the workflow exports only run_all and only_testing
#     to $GITHUB_OUTPUT regardless.
set -euo pipefail

file="${1:?selection.json}"
conclusion="${2:-failure}"

ALLOWED="SearchFlowUITests FavoritesFlowUITests AccessibilityAuditUITests ScreenshotGalleryUITests LaunchTests"
FLOOR="LaunchTests"

one_line() { printf '%s' "$1" | tr -d '\000-\037\177' | head -c 300; }

run_all=true
reason=""
classes=""
flags=""

if [ "$conclusion" != "success" ]; then
  reason="selection did not complete (conclusion: $(one_line "$conclusion")); running the full suite"
elif ! [ -s "$file" ] || ! jq -e 'type == "object" and (.classes | type == "array") and (.run_all | type == "boolean")' "$file" >/dev/null 2>&1; then
  reason="selection output was empty or malformed; running the full suite"
elif [ "$(jq -r '.run_all' "$file")" = "true" ]; then
  reason="$(one_line "$(jq -r '.summary // "selection asked for the full suite"' "$file")")"
else
  run_all=false
  reason="$(one_line "$(jq -r '.summary // "selected from the diff"' "$file")")"
  picked="$( { jq -r '.classes[]' "$file"; echo "$FLOOR"; } | sort -u )"
  for c in $picked; do
    case " $ALLOWED " in
      *" $c "*)
        classes="${classes:+$classes }$c"
        flags="${flags:+$flags }-only-testing:testExampleUITests/$c"
        ;;
      *) echo "ignoring unknown class '$(one_line "$c")'" >&2 ;;
    esac
  done
fi

printf 'run_all=%s\n' "$run_all"
printf 'only_testing=%s\n' "$flags"
printf 'classes=%s\n' "$classes"
printf 'reason=%s\n' "$reason"
