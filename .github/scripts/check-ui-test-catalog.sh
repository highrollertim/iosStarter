#!/usr/bin/env bash
# The selection catalog, the schema's enum, and decide-ui-tests.sh's allowlist
# must all name exactly the XCTestCase classes that exist in the UI test
# target. A renamed or added class otherwise falls through "ignoring unknown
# class" and quietly shrinks coverage.
#
# Paths can be overridden for the self-test in test-check-ui-test-catalog.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

UITESTS_DIR="${UITESTS_DIR:-testExample/testExampleUITests}"
SCHEMA_FILE="${SCHEMA_FILE:-.claude/skills/select-ui-tests/selection.schema.json}"
DECIDE_FILE="${DECIDE_FILE:-.github/scripts/decide-ui-tests.sh}"
SKILL_FILE="${SKILL_FILE:-.claude/skills/select-ui-tests/SKILL.md}"

# `|| true` on every grep: a grep that selects nothing is a mismatch for the
# comparison below to report, not a reason to abort.
actual="$( { grep -rhE '^(final )?class [A-Za-z0-9_]+: XCTestCase' "$UITESTS_DIR" --include='*.swift' || true; } | sed -E 's/^(final )?class ([A-Za-z0-9_]+):.*/\2/' | sort)"
schema="$(jq -r '.properties.classes.items.enum[]' "$SCHEMA_FILE" | sort)"
allow="$( { sed -n -E 's/^ALLOWED="([^"]+)"$/\1/p' "$DECIDE_FILE" || true; } | tr ' ' '\n' | sort)"
catalog="$( { grep -o -E '^\| `[A-Za-z0-9_]+`' "$SKILL_FILE" || true; } | sed -E 's/^\| `([A-Za-z0-9_]+)`/\1/' | grep -v '^Class$' | sort)"

status=0
for pair in "schema enum:$schema" "decide allowlist:$allow" "skill catalog:$catalog"; do
  name="${pair%%:*}"; got="${pair#*:}"
  if [ -n "$actual" ] && [ "$got" = "$actual" ]; then
    echo "ok   $name matches the UI test target"
  else
    echo "FAIL $name differs from the UI test target"
    diff <(echo "$actual") <(echo "$got") || true
    status=1
  fi
done
exit $status
