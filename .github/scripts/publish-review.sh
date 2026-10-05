#!/usr/bin/env bash
# Turn the review's structured verdict into one pull request review.
#
# Inputs: $1 is a file holding the structured_output JSON from the action.
# Env:    PR (number), REVIEW_CONCLUSION (the action's conclusion output),
#         GH_TOKEN, GITHUB_REPOSITORY.
#
# One review is submitted per run; GitHub stacks them in the PR's review
# history, and a newer APPROVE or REQUEST_CHANGES from the same account
# supersedes the older one for merge purposes. The verdict maps to an event:
#   pass              -> APPROVE
#   changes_requested -> REQUEST_CHANGES
#   needs_human       -> COMMENT, plus the needs-human-review label
#   did not run       -> COMMENT saying so, and exit 1 so the check is red
#
# Findings with a line number are posted as inline review comments on the
# diff. Two rejections are handled by kind, read from the API's error body:
#   - a line outside the diff: resubmitted with the findings in the body
#   - approval not permitted (the repository setting "Allow GitHub Actions
#     to create and approve pull requests" is off): resubmitted as COMMENT
#     with a line saying the verdict was pass, and exit 0, because a clean
#     pass must not turn red over a settings toggle
set -euo pipefail

file="${1:?structured output file}"
pr="${PR:?PR number}"
conclusion="${REVIEW_CONCLUSION:-failure}"
api="repos/${GITHUB_REPOSITORY}/pulls/${pr}/reviews"
errfile="$(mktemp)"; trap 'rm -f "$errfile"' EXIT

submit() { # $1 event, $2 body, $3 comments json array or empty -> prints url, or returns 1 with the error in $errfile
  local event="$1" body="$2" comments="${3:-}" payload
  if [ -n "$comments" ] && [ "$comments" != "[]" ]; then
    payload="$(jq -n --arg e "$event" --arg b "$body" --argjson c "$comments" '{event:$e, body:$b, comments:$c}')"
  else
    payload="$(jq -n --arg e "$event" --arg b "$body" '{event:$e, body:$b}')"
  fi
  gh api --method POST "$api" --input - <<<"$payload" --jq '.html_url' 2>"$errfile"
}

if [ "$conclusion" != "success" ] || ! jq -e '.verdict' "$file" >/dev/null 2>&1; then
  body="$(printf '## Claude review: did not run\n\nThe review step finished with conclusion `%s` and no valid verdict. This is not an approval. Re-run the job, or review by hand.\n' "$conclusion")"
  submit COMMENT "$body" "" >/dev/null
  echo "Posted did-not-run review; failing the step so the check cannot read as a pass" >&2
  exit 1
fi

verdict="$(jq -r '.verdict' "$file")"
case "$verdict" in
  pass) event=APPROVE; title="Claude review: approved" ;;
  changes_requested) event=REQUEST_CHANGES; title="Claude review: changes requested" ;;
  *) event=COMMENT; title="Claude review: needs a human" ;;
esac

render_body() { # $1 title, $2 optional preface line
  jq -r --arg title "$1" --arg preface "${2:-}" '
    def sev_icon: if . == "blocker" then "🟥" elif . == "major" then "🟧" else "🟨" end;
    [ "## \($title)",
      (if $preface != "" then "\n" + $preface else empty end),
      "",
      .summary,
      "",
      "**Risk tag expected:** `\(.risk_tag_expected)`  ",
      "**Tests adequate:** \(if .tests.adequate then "yes" else "no" end)" +
        (if (.tests.gaps | length) > 0 then "\n\nGaps:\n" + (.tests.gaps | map("- " + .) | join("\n")) else "" end),
      "",
      (if (.findings | length) == 0 then "_No findings._" else
        "### Findings\n\n" + (.findings | map(
          "\(.severity | sev_icon) **\(.title)** — `\(.file)`" + (if .line then ":\(.line)" else "" end) + "\n" +
          "  \(.rationale)\n" +
          "  _Suggested fix:_ \(.suggested_fix)"
        ) | join("\n\n")) end),
      "",
      "<sub>Review by Claude Code via anthropics/claude-code-action using `.claude/skills/review-pr`. Run `/review-pr <number>` locally to reproduce.</sub>"
    ] | join("\n")' "$file"
}

body="$(render_body "$title")"
# GitHub caps a review body at 65536 characters. A verdict with many long
# findings is truncated with a note rather than rejected.
if [ "${#body}" -gt 60000 ]; then
  body="${body:0:60000}"$'\n\n'"_Truncated: the full verdict is in the workflow artifact._"
fi

# Inline comments for findings that name a line.
comments="$(jq -c '
  def sev_icon: if . == "blocker" then "🟥" elif . == "major" then "🟧" else "🟨" end;
  [ .findings[] | select(.line != null) |
    { path: .file, line: .line, side: "RIGHT",
      body: "\(.severity | sev_icon) **\(.title)**\n\n\(.rationale)\n\n_Suggested fix:_ \(.suggested_fix)" } ]' "$file")"

if url="$(submit "$event" "$body" "$comments")"; then
  echo "Submitted $event review ($(jq 'length' <<<"$comments") inline comments): $url"
else
  err="$(cat "$errfile")"
  if [ "$event" = "APPROVE" ] && grep -qi -E 'not permitted to (create and )?approve|not allowed to approve' <<<"$err"; then
    echo "Approval rejected by GitHub (the repository setting that lets Actions approve pull requests is off); submitting as a comment instead" >&2
    body="$(render_body "Claude review: pass (approval disabled)" "Verdict was **pass**, but this repository does not allow GitHub Actions to approve pull requests, so this is posted as a comment. Turn on \"Allow GitHub Actions to create and approve pull requests\" under Settings > Actions > General for the approval to count.")"
    url="$(submit COMMENT "$body" "$comments" || submit COMMENT "$body" "")"
    echo "Submitted COMMENT review: $url"
  elif grep -qi -E 'must be part of the diff|PullRequestReviewThread|pull_request_review_thread' <<<"$err"; then
    echo "Inline comments rejected (a line outside the diff); resubmitting with findings in the body only" >&2
    url="$(submit "$event" "$body" "")"
    echo "Submitted $event review: $url"
  else
    echo "Review submission failed: $err" >&2
    exit 1
  fi
fi

if [ "$verdict" = "needs_human" ]; then
  gh pr edit "$pr" --add-label "needs-human-review" >/dev/null 2>&1 || true
fi
