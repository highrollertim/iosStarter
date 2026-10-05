#!/usr/bin/env bash
# Fixture tests for decide-ui-tests.sh. Runs in seconds on any runner with jq.
# Every assertion compares a whole KEY=VALUE line, so a trailing addition or
# a leaked flag fails rather than slipping past a substring match.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

value() { sed -n "s/^$2=//p" <<<"$1"; }                       # output, key
expect() {                                                     # name, output, key, exact value
  local got; got="$(value "$2" "$3")"
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "   $3 expected: [$4]"; echo "   $3 got:      [$got]"; fail=1; fi
}
count_lines() { grep -c "^$2=" <<<"$1" || true; }              # output, key

# 1. A narrow selection runs the picks plus the floor, sorted, nothing else.
echo '{"run_all":false,"classes":["SearchFlowUITests"],"reasons":["x"],"summary":"search only"}' > "$tmp/a.json"
out="$(./decide-ui-tests.sh "$tmp/a.json" success)"
expect "narrow: run_all" "$out" run_all false
expect "narrow: flags are floor plus pick" "$out" only_testing "-only-testing:testExampleUITests/LaunchTests -only-testing:testExampleUITests/SearchFlowUITests"
expect "narrow: classes" "$out" classes "LaunchTests SearchFlowUITests"

# 2. run_all from the model runs everything, with no flags at all.
echo '{"run_all":true,"classes":[],"reasons":[],"summary":"workflow changed"}' > "$tmp/b.json"
out="$(./decide-ui-tests.sh "$tmp/b.json" success)"
expect "model run_all" "$out" run_all true
expect "model run_all: no flags" "$out" only_testing ""
expect "model run_all: reason passthrough" "$out" reason "workflow changed"

# 3. A failed action conclusion runs everything, whatever the file says.
out="$(./decide-ui-tests.sh "$tmp/a.json" failure)"
expect "failed conclusion" "$out" run_all true
expect "failed conclusion: no flags" "$out" only_testing ""

# 4. An empty file runs everything.
: > "$tmp/c.json"
out="$(./decide-ui-tests.sh "$tmp/c.json" success)"
expect "empty file" "$out" run_all true

# 5. Malformed JSON runs everything.
echo '{"classes":"nope"' > "$tmp/d.json"
out="$(./decide-ui-tests.sh "$tmp/d.json" success)"
expect "malformed" "$out" run_all true

# 6. An unknown class name never reaches the command line.
echo '{"run_all":false,"classes":["Evil; rm -rf /","FavoritesFlowUITests"],"reasons":[],"summary":"s"}' > "$tmp/e.json"
out="$(./decide-ui-tests.sh "$tmp/e.json" success 2>/dev/null)"
expect "unknown dropped" "$out" only_testing "-only-testing:testExampleUITests/FavoritesFlowUITests -only-testing:testExampleUITests/LaunchTests"
if [[ "$out" == *"Evil"* ]]; then echo "FAIL unknown leaked into output"; fail=1; else echo "ok   unknown not leaked"; fi

# 7. Empty classes with run_all false still runs the floor.
echo '{"run_all":false,"classes":[],"reasons":[],"summary":"docs only"}' > "$tmp/f.json"
out="$(./decide-ui-tests.sh "$tmp/f.json" success)"
expect "floor only" "$out" only_testing "-only-testing:testExampleUITests/LaunchTests"

# 8. A summary carrying a newline and a second KEY=VALUE cannot inject a key.
jq -n '{run_all:false, classes:["SearchFlowUITests"], reasons:[], summary:"ok\nonly_testing=-only-testing:Evil\nrun_all=true"}' > "$tmp/g.json"
out="$(./decide-ui-tests.sh "$tmp/g.json" success)"
expect "injection: reason flattened" "$out" reason "okonly_testing=-only-testing:Evilrun_all=true"
expect "injection: only_testing intact" "$out" only_testing "-only-testing:testExampleUITests/LaunchTests -only-testing:testExampleUITests/SearchFlowUITests"
if [ "$(count_lines "$out" only_testing)" = "1" ] && [ "$(count_lines "$out" run_all)" = "1" ]; then echo "ok   injection: one line per key"; else echo "FAIL injection: duplicate keys"; fail=1; fi

# 9. A very long summary is capped.
jq -n --arg s "$(head -c 2000 /dev/zero | tr '\0' 'x')" '{run_all:true, classes:[], reasons:[], summary:$s}' > "$tmp/h.json"
out="$(./decide-ui-tests.sh "$tmp/h.json" success)"
if [ "${#out}" -lt 400 ]; then echo "ok   long summary capped"; else echo "FAIL long summary not capped (${#out} chars)"; fail=1; fi

exit $fail
