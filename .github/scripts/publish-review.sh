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

# GitHub caps a review body at 65536 characters. A verdict with many long
# findings is truncated with a note rather than rejected.
capped() { local b="$1"; if [ "${#b}" -gt 60000 ]; then b="${b:0:60000}"$'\n\n'"_Truncated: the full verdict is in the workflow artifact._"; fi; printf '%s' "$b"; }

# GitHub keeps one review state per reviewer, and a COMMENT does not change
# it. A standing APPROVE from this account must be dismissed before any
# verdict that is not a pass, or a later did-not-run or needs-human run
# leaves the old approval satisfying "require N approvals". Branch protection's
# "dismiss stale approvals on push" is the belt; this is the suspenders.
dismiss_prior_approvals() { # $1 reason
  local me ids id
  me="$(gh api user --jq .login 2>/dev/null || echo "github-actions[bot]")"
  ids="$(gh api "$api" --paginate --jq ".[] | select(.state == \"APPROVED\" and .user.login == \"$me\") | .id" 2>/dev/null || true)"
  for id in $ids; do
    if gh api --method PUT "$api/$id/dismissals" -f message="$1" >/dev/null 2>&1; then
      echo "Dismissed prior approval $id: $1"
    else
      # A standing approval that cannot be dismissed must not be left to
      # satisfy the branch rule under a non-pass verdict. Fail loudly.
      echo "could not dismiss prior approval $id; failing so the stale approval is noticed" >&2
      exit 1
    fi
  done
}


if [ "$conclusion" != "success" ] || ! jq -e '.verdict' "$file" >/dev/null 2>&1; then
  body="$(printf '## Claude review: did not run\n\nThe review step finished with conclusion `%s` and no valid verdict. This is not an approval. Re-run the job, or review by hand.\n' "$conclusion")"
  dismiss_prior_approvals "Superseded: a later review run did not complete."
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

body="$(capped "$(render_body "$title")")"

if [ "$event" != "APPROVE" ]; then
  dismiss_prior_approvals "Superseded by a newer review: $verdict."
fi

# Inline comments for findings that name a line.
comments="$(jq -c '
  def sev_icon: if . == "blocker" then "🟥" elif . == "major" then "🟧" else "🟨" end;
  [ .findings[] | select(.line != null) |
    { path: .file, line: .line, side: "RIGHT",
      body: "\(.severity | sev_icon) **\(.title)**\n\n\(.rationale)\n\n_Suggested fix:_ \(.suggested_fix)" } ]' "$file")"

# Submission, in three tiers. Any failure of the inline-comment form is
# retried without inline comments, whatever GitHub's reason: a line outside
# the diff, a file not in the diff, a position the API will not accept.
# Only a failure of the body-only form is classified.
url=""
if url="$(submit "$event" "$body" "$comments")"; then
  echo "Submitted $event review ($(jq 'length' <<<"$comments") inline comments): $url"
else
  first_err="$(cat "$errfile")"
  if [ -n "$comments" ] && [ "$comments" != "[]" ] && url="$(submit "$event" "$body" "")"; then
    echo "Inline comments rejected, resubmitted with findings in the body only. GitHub said: ${first_err:0:200}" >&2
    echo "Submitted $event review: $url"
  else
    err="$(cat "$errfile")"
    if [ "$event" = "APPROVE" ] && grep -qi -E 'not permitted to (create and )?approve|not allowed to approve' <<<"$err"; then
      echo "Approval rejected by GitHub (the repository setting that lets Actions approve pull requests is off); submitting as a comment instead" >&2
      body="$(capped "$(render_body "Claude review: pass (approval disabled)" "Verdict was **pass**, but this repository does not allow GitHub Actions to approve pull requests, so this is posted as a comment. Turn on \"Allow GitHub Actions to create and approve pull requests\" under Settings > Actions > General for the approval to count.")")"
      # Status captured explicitly: this is the pass path, and it must stay
      # green even if both comment attempts fail on a transient error.
      url="$(submit COMMENT "$body" "$comments" || submit COMMENT "$body" "" || true)"
      if [ -n "$url" ]; then echo "Submitted COMMENT review: $url"; else echo "warning: could not post the pass as a comment: $(cat "$errfile")" >&2; fi
    else
      echo "Review submission failed: $err" >&2
      exit 1
    fi
  fi
fi

if [ "$verdict" = "needs_human" ]; then
  gh pr edit "$pr" --add-label "needs-human-review" >/dev/null 2>&1 || true
fi
