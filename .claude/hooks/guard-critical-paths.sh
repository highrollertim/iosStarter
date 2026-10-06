#!/usr/bin/env bash
# PreToolUse guard: block agent edits to critical paths.
#
# Claude Code pipes the tool call as JSON on stdin. For Edit, Write and
# MultiEdit the file is at .tool_input.file_path. Exit 2 blocks the call and
# sends stderr back to the model as the reason; exit 0 lets it through.
#
# This is the paved road, not the gate: it stops the agent, not a person with
# an editor. CI is the gate. Set HARNESS_ALLOW_CRITICAL=1 to lift the block
# for a session that is deliberately doing risk:critical work.
set -euo pipefail

input="$(cat)"
path="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
ti = d.get("tool_input") or {}
print(ti.get("file_path") or ti.get("path") or "")')"

[ -z "$path" ] && exit 0

case "$path" in
  *.github/workflows/*|*.github/scripts/*|*project.pbxproj|*PrivacyInfo.xcprivacy|*.xctestplan|*.claude/settings.json|*.claude/hooks/*)
    if [ "${HARNESS_ALLOW_CRITICAL:-}" = "1" ]; then
      exit 0
    fi
    echo "Blocked by the harness: '$path' is a critical path (CI workflow or script, Xcode project file, privacy manifest, test plan, or harness config). Change it by hand in a PR tagged risk:critical, or rerun with HARNESS_ALLOW_CRITICAL=1 if this session is deliberately doing that work." >&2
    exit 2
    ;;
esac

exit 0
