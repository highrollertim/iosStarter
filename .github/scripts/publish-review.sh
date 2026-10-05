#!/usr/bin/env bash
# Turn the review's structured verdict into one pull request review.
#
# Inputs: $1 is a file holding the structured_output JSON from the action.
# Env:    PR (number), REVIEW_CONCLUSION (the action's conclusion output),
#         GH_TOKEN, GITHUB_REPOSITORY.
#
# The verdict maps to a review event, not a comment:
#   pass              -> APPROVE
#   changes_requested -> REQUEST_CHANGES
#   needs_human       -> COMMENT, plus the needs-human-review label
#   did not run       -> COMMENT saying so; never an approval
#
# Findings with a line number are posted as inline review comments on the
# diff. If GitHub rejects the inline set (a line outside the diff is the
# usual cause), the review is resubmitted with the findings in the body.
#
# Approval by the workflow token needs the repository setting "Allow GitHub
# Actions to create and approve pull requests" turned on. A bot approval
# satisfies a plain "require N approvals" rule and does not satisfy "require
# review from Code Owners", which is the intended split between Routine and
# everything else.
set -euo pipefail

file="${1:?structured output file}"
pr="${PR:?PR number}"
conclusion="${REVIEW_CONCLUSION:-failure}"
marker="<!-- claude-pr-review -->"
api="repos/${GITHUB_REPOSITORY}/pulls/${pr}/reviews"

submit() { # $1 event, $2 body, $3 comments json array or empty
  local event="$1" body="$2" comments="${3:-}"
  local payload
  if [ -n "$comments" ] && [ "$comments" != "[]" ]; then
    payload="$(jq -n --arg e "$event" --arg b "$body" --argjson c "$comments" '{event:$e, body:$b, comments:$c}')"
  else
    payload="$(jq -n --arg e "$event" --arg b "$body" '{event:$e, body:$b}')"
  fi
  gh api --method POST "$api" --input - <<<"$payload" --jq '.html_url'
}

if [ "$conclusion" != "success" ] || ! jq -e '.verdict' "$file" >/dev/null 2>&1; then
  body="$(printf '%s\n## Claude review: did not run\n\nThe review step finished with conclusion `%s` and no valid verdict. This is not an approval. Re-run the job, or review by hand.\n' "$marker" "$conclusion")"
  submit COMMENT "$body" ""
  echo "Posted did-not-run review"
  exit 0
fi

verdict="$(jq -r '.verdict' "$file")"
case "$verdict" in
  pass) event=APPROVE; title="Claude review: approved" ;;
  changes_requested) event=REQUEST_CHANGES; title="Claude review: changes requested" ;;
  *) event=COMMENT; title="Claude review: needs a human" ;;
esac

body="$(jq -r --arg marker "$marker" --arg title "$title" '
  def sev_icon: if . == "blocker" then "🟥" elif . == "major" then "🟧" else "🟨" end;
  [ $marker,
    "## \($title)",
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
  ] | join("\n")' "$file")"

# Inline comments for findings that name a line. Severity icon in each.
comments="$(jq -c '
  def sev_icon: if . == "blocker" then "🟥" elif . == "major" then "🟧" else "🟨" end;
  [ .findings[] | select(.line != null) |
    { path: .file, line: .line, side: "RIGHT",
      body: "\(.severity | sev_icon) **\(.title)**\n\n\(.rationale)\n\n_Suggested fix:_ \(.suggested_fix)" } ]' "$file")"

if url="$(submit "$event" "$body" "$comments" 2>/dev/null)"; then
  echo "Submitted $event review ($(jq 'length' <<<"$comments") inline comments): $url"
else
  echo "Inline comments rejected (a line outside the diff, most likely); resubmitting with findings in the body only" >&2
  url="$(submit "$event" "$body" "")"
  echo "Submitted $event review: $url"
fi

if [ "$verdict" = "needs_human" ]; then
  gh pr edit "$pr" --add-label "needs-human-review" >/dev/null 2>&1 || true
fi
