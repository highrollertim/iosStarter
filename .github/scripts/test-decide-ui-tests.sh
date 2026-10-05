#!/usr/bin/env bash
# Fixture tests for decide-ui-tests.sh. Runs in seconds on any runner with jq.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
check() { # name, expected substring, actual
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "   expected: $2"; echo "   got:      $3"; fail=1; fi
}

# 1. A narrow selection runs the picks plus the floor, sorted, nothing else.
echo '{"run_all":false,"classes":["SearchFlowUITests"],"reasons":["x"],"summary":"search only"}' > "$tmp/a.json"
out="$(./decide-ui-tests.sh "$tmp/a.json" success)"
check "narrow: run_all false" "run_all=false" "$out"
check "narrow: floor added" "only_testing=-only-testing:testExampleUITests/LaunchTests -only-testing:testExampleUITests/SearchFlowUITests" "$out"

# 2. run_all from the model runs everything.
echo '{"run_all":true,"classes":[],"reasons":[],"summary":"workflow changed"}' > "$tmp/b.json"
out="$(./decide-ui-tests.sh "$tmp/b.json" success)"
check "model run_all" "run_all=true" "$out"
check "model run_all: no flags" "only_testing=" "$out"

# 3. A failed action conclusion runs everything, whatever the file says.
out="$(./decide-ui-tests.sh "$tmp/a.json" failure)"
check "failed conclusion" "run_all=true" "$out"
check "failed conclusion reason" "did not complete" "$out"

# 4. An empty file runs everything.
: > "$tmp/c.json"
out="$(./decide-ui-tests.sh "$tmp/c.json" success)"
check "empty file" "run_all=true" "$out"

# 5. Malformed JSON runs everything.
echo '{"classes":"nope"' > "$tmp/d.json"
out="$(./decide-ui-tests.sh "$tmp/d.json" success)"
check "malformed" "run_all=true" "$out"

# 6. An unknown class name never reaches the command line.
echo '{"run_all":false,"classes":["Evil; rm -rf /","FavoritesFlowUITests"],"reasons":[],"summary":"s"}' > "$tmp/e.json"
out="$(./decide-ui-tests.sh "$tmp/e.json" success 2>/dev/null)"
check "unknown dropped" "only_testing=-only-testing:testExampleUITests/FavoritesFlowUITests -only-testing:testExampleUITests/LaunchTests" "$out"
if [[ "$out" == *"Evil"* ]]; then echo "FAIL unknown leaked"; fail=1; else echo "ok   unknown not leaked"; fi

# 7. Empty classes with run_all false still runs the floor.
echo '{"run_all":false,"classes":[],"reasons":[],"summary":"docs only"}' > "$tmp/f.json"
out="$(./decide-ui-tests.sh "$tmp/f.json" success)"
check "floor only" "only_testing=-only-testing:testExampleUITests/LaunchTests" "$out"

exit $fail
