#!/usr/bin/env bash
# Self-test for check-ui-test-catalog.sh: it must pass on the real tree and
# fail when any one of the three lists drifts from the UI test target.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
expect() { # name, expected exit, actual exit
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected exit $2, got $3)"; fail=1; fi
}
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# 1. The real tree passes.
expect "real tree passes" 0 "$(rc_of bash "$here/check-ui-test-catalog.sh")"

# 2. A class renamed in the target, including one in a subdirectory, fails.
cp -R "$root/testExample/testExampleUITests" "$tmp/ui"
mkdir -p "$tmp/ui/Nested"
printf 'import XCTest\nfinal class BrandNewUITests: XCTestCase {}\n' > "$tmp/ui/Nested/BrandNewUITests.swift"
expect "new class in a subdirectory fails" 1 "$(rc_of env UITESTS_DIR="$tmp/ui" bash "$here/check-ui-test-catalog.sh")"

# 3. A schema enum missing a class fails.
jq 'del(.properties.classes.items.enum[0])' "$root/.claude/skills/select-ui-tests/selection.schema.json" > "$tmp/schema.json"
expect "schema drift fails" 1 "$(rc_of env SCHEMA_FILE="$tmp/schema.json" bash "$here/check-ui-test-catalog.sh")"

# 4. An allowlist missing a class fails.
sed -E 's/^ALLOWED="SearchFlowUITests /ALLOWED="/' "$root/.github/scripts/decide-ui-tests.sh" > "$tmp/decide.sh"
expect "allowlist drift fails" 1 "$(rc_of env DECIDE_FILE="$tmp/decide.sh" bash "$here/check-ui-test-catalog.sh")"

# 5. A catalog row removed from the skill fails.
grep -v '^| `FavoritesFlowUITests`' "$root/.claude/skills/select-ui-tests/SKILL.md" > "$tmp/SKILL.md"
expect "catalog drift fails" 1 "$(rc_of env SKILL_FILE="$tmp/SKILL.md" bash "$here/check-ui-test-catalog.sh")"

# 6. An empty target directory fails rather than passing on empty-equals-empty.
mkdir -p "$tmp/empty"
expect "empty target fails" 1 "$(rc_of env UITESTS_DIR="$tmp/empty" bash "$here/check-ui-test-catalog.sh")"

exit $fail
