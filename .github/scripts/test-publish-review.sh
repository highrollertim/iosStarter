#!/usr/bin/env bash
# Fixture tests for publish-review.sh with a stubbed `gh`. Checks the review
# event for each verdict, the inline-comment fallback, the approval-disabled
# fallback, and that "did not run" exits nonzero so the check cannot read as
# a pass.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

# Stub gh: records each review POST's event and comment count.
#   REJECT_INLINE=1   a POST with inline comments fails like a line outside the diff
#   REJECT_APPROVE=1  a POST with event APPROVE fails like the settings toggle being off
cat > "$tmp/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "POST" ]; then
  payload="$(cat)"
  n="$(jq '.comments | length' <<<"$payload" 2>/dev/null || echo 0)"
  ev="$(jq -r '.event' <<<"$payload")"
  if [ "${REJECT_APPROVE:-0}" = "1" ] && [ "$ev" = "APPROVE" ]; then
    echo 'gh: Unprocessable Entity (HTTP 422): GitHub Actions is not permitted to approve pull requests.' >&2; exit 1
  fi
  if [ "${REJECT_INLINE:-0}" = "1" ] && [ "$n" -gt 0 ]; then
    echo 'gh: Unprocessable Entity (HTTP 422): Pull request review thread line must be part of the diff' >&2; exit 1
  fi
  echo "$ev comments=$n" >> "$STUB_LOG"
  echo "https://example.test/review"; exit 0
fi
exit 0
EOF
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH" GITHUB_REPOSITORY=o/r PR=1 GH_TOKEN=x STUB_LOG="$tmp/log"

run() { : > "$STUB_LOG"; REVIEW_CONCLUSION="$1" bash "$here/publish-review.sh" "$2" >/dev/null 2>&1; echo "exit=$? $(tr '\n' ' ' < "$STUB_LOG" | sed 's/ $//')"; }
check() { if [ "$3" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "   expected: [$2]"; echo "   got:      [$3]"; fail=1; fi; }

base='{"risk_tag_expected":"routine","summary":"s","tests":{"adequate":true,"gaps":[]},"findings":[]}'
jq '.verdict="pass"' <<<"$base" > "$tmp/pass.json"
jq '.verdict="changes_requested" | .findings=[{"severity":"major","file":"a.swift","line":3,"title":"t","rationale":"r","suggested_fix":"f"}]' <<<"$base" > "$tmp/cr.json"
jq '.verdict="needs_human"' <<<"$base" > "$tmp/nh.json"
: > "$tmp/empty.json"

check "pass approves"              "exit=0 APPROVE comments=0"         "$(run success "$tmp/pass.json")"
check "changes requested inline"   "exit=0 REQUEST_CHANGES comments=1" "$(run success "$tmp/cr.json")"
check "needs human comments"       "exit=0 COMMENT comments=0"         "$(run success "$tmp/nh.json")"
check "did not run: failure"       "exit=1 COMMENT comments=0"         "$(run failure "$tmp/pass.json")"
check "did not run: empty"         "exit=1 COMMENT comments=0"         "$(run success "$tmp/empty.json")"
check "inline rejected falls back" "exit=0 REQUEST_CHANGES comments=0" "$(REJECT_INLINE=1 run success "$tmp/cr.json")"
check "approval disabled: comment, green" "exit=0 COMMENT comments=0"  "$(REJECT_APPROVE=1 run success "$tmp/pass.json")"

exit $fail
