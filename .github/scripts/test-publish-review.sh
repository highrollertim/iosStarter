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
  if [ "${REJECT_OTHER:-0}" = "1" ]; then
    echo 'gh: Internal Server Error (HTTP 500)' >&2; exit 1
  fi
  if [ "${REJECT_APPROVE:-0}" = "1" ] && [ "$ev" = "APPROVE" ]; then
    echo 'gh: Unprocessable Entity (HTTP 422): GitHub Actions is not permitted to approve pull requests.' >&2; exit 1
  fi
  if [ "${REJECT_INLINE:-0}" = "1" ] && [ "$n" -gt 0 ]; then
    echo 'gh: Unprocessable Entity (HTTP 422): Validation Failed: path is not part of the diff (some other wording)' >&2; exit 1
  fi
  echo "$ev comments=$n" >> "$STUB_LOG"
  echo "https://example.test/review"; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  echo "label $5" >> "$STUB_LOG"; exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then echo "github-actions[bot]"; exit 0; fi
if [ "$1" = "api" ] && [ "$2" = "--method" ] && [ "$3" = "PUT" ] && [[ "$4" == */dismissals ]]; then
  if [ "${DISMISS_FAIL:-0}" = "1" ]; then echo "gh: Forbidden (HTTP 403)" >&2; exit 1; fi
  echo "dismiss ${4##*/reviews/}" | sed 's|/dismissals||' >> "$STUB_LOG"; exit 0
fi
if [ "$1" = "api" ] && [[ "$2" == */reviews ]]; then
  if [ "${PRIOR_APPROVAL:-0}" = "1" ]; then echo "77"; fi; exit 0
fi
exit 0
EOF
chmod +x "$tmp/gh"
export PATH="$tmp:$PATH" GITHUB_REPOSITORY=o/r PR=1 GH_TOKEN=x STUB_LOG="$tmp/log"

# The status is captured with `|| rc=$?` so the assertion never depends on
# whether errexit reaches into a command substitution.
run() { : > "$STUB_LOG"; local rc=0 log; REVIEW_CONCLUSION="$1" bash "$here/publish-review.sh" "$2" >/dev/null 2>&1 || rc=$?; log="$(tr '\n' ' ' < "$STUB_LOG" | sed 's/ $//')"; echo "exit=$rc${log:+ $log}"; }
check() { if [ "$3" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "   expected: [$2]"; echo "   got:      [$3]"; fail=1; fi; }

base='{"risk_tag_expected":"routine","summary":"s","tests":{"adequate":true,"gaps":[]},"findings":[]}'
jq '.verdict="pass"' <<<"$base" > "$tmp/pass.json"
jq '.verdict="changes_requested" | .findings=[{"severity":"major","file":"a.swift","line":3,"title":"t","rationale":"r","suggested_fix":"f"}]' <<<"$base" > "$tmp/cr.json"
jq '.verdict="needs_human"' <<<"$base" > "$tmp/nh.json"
: > "$tmp/empty.json"

check "pass approves"              "exit=0 APPROVE comments=0"         "$(run success "$tmp/pass.json")"
check "changes requested inline"   "exit=0 REQUEST_CHANGES comments=1" "$(run success "$tmp/cr.json")"
check "needs human comments and labels" "exit=0 COMMENT comments=0 label needs-human-review" "$(run success "$tmp/nh.json")"
jq '.verdict="pass" | .summary=("x" * 70000)' <<<"$base" > "$tmp/long.json"
check "very long body still approves" "exit=0 APPROVE comments=0"       "$(run success "$tmp/long.json")"
check "did not run: failure"       "exit=1 COMMENT comments=0"         "$(run failure "$tmp/pass.json")"
check "did not run: empty"         "exit=1 COMMENT comments=0"         "$(run success "$tmp/empty.json")"
check "inline rejected falls back" "exit=0 REQUEST_CHANGES comments=0" "$(REJECT_INLINE=1 run success "$tmp/cr.json")"
check "approval disabled: comment, green" "exit=0 COMMENT comments=0"  "$(REJECT_APPROVE=1 run success "$tmp/pass.json")"
check "unrelated failure: red"     "exit=1"                            "$(REJECT_OTHER=1 run success "$tmp/pass.json")"
check "prior approval kept on pass"          "exit=0 APPROVE comments=0"                         "$(PRIOR_APPROVAL=1 run success "$tmp/pass.json")"
check "prior approval dismissed on changes"  "exit=0 dismiss 77 REQUEST_CHANGES comments=1"      "$(PRIOR_APPROVAL=1 run success "$tmp/cr.json")"
check "prior approval dismissed on needs human" "exit=0 dismiss 77 COMMENT comments=0 label needs-human-review" "$(PRIOR_APPROVAL=1 run success "$tmp/nh.json")"
check "prior approval dismissed on did not run" "exit=1 dismiss 77 COMMENT comments=0"           "$(PRIOR_APPROVAL=1 run failure "$tmp/pass.json")"
check "dismissal failure is red"             "exit=1"                                            "$(PRIOR_APPROVAL=1 DISMISS_FAIL=1 run success "$tmp/nh.json")"

exit $fail
