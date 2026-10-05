#!/usr/bin/env bash
# The selection catalog, the schema's enum, and decide-ui-tests.sh's allowlist
# must all name exactly the XCTestCase classes that exist in the UI test
# target. A renamed or added class otherwise falls through "ignoring unknown
# class" and quietly shrinks coverage.
set -euo pipefail
cd "$(dirname "$0")/../.."

actual="$(grep -h -E '^(final )?class [A-Za-z0-9_]+: XCTestCase' testExample/testExampleUITests/*.swift | sed -E 's/^(final )?class ([A-Za-z0-9_]+):.*/\2/' | sort)"
schema="$(jq -r '.properties.classes.items.enum[]' .claude/skills/select-ui-tests/selection.schema.json | sort)"
allow="$(sed -n -E 's/^ALLOWED="([^"]+)"$/\1/p' .github/scripts/decide-ui-tests.sh | tr ' ' '\n' | sort)"
catalog="$(grep -o -E '^\| `[A-Za-z0-9_]+UITests`|^\| `LaunchTests`' .claude/skills/select-ui-tests/SKILL.md | sed -E 's/^\| `([A-Za-z0-9_]+)`/\1/' | sort)"

status=0
for pair in "schema enum:$schema" "decide allowlist:$allow" "skill catalog:$catalog"; do
  name="${pair%%:*}"; got="${pair#*:}"
  if [ "$got" = "$actual" ]; then
    echo "ok   $name matches the UI test target"
  else
    echo "FAIL $name differs from the UI test target"
    diff <(echo "$actual") <(echo "$got") || true
    status=1
  fi
done
exit $status
