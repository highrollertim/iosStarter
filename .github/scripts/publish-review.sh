#!/usr/bin/env bash
# Turn the headless review's JSON into one PR comment, edited in place.
#
# Inputs: $1 is the review.json from `claude -p --output-format json`.
# Env:    PR (number), REVIEW_EXIT (the claude exit code), GH_TOKEN.
#
# The comment carries a hidden marker so re-runs update the same comment
# instead of stacking a new one per push. A nonzero exit code, or a result
# that does not match the schema, is reported as "review did not run" and
# never as a pass.
set -euo pipefail

file="${1:?review.json path}"
pr="${PR:?PR number}"
exit_code="${REVIEW_EXIT:-1}"
marker="<!-- claude-pr-review -->"

body=""
if [ "$exit_code" != "0" ] || ! jq -e '.structured_output.verdict' "$file" >/dev/null 2>&1; then
  reason="$(jq -r '.result // empty' "$file" 2>/dev/null | head -c 1500 || true)"
  body="$(printf '%s\n## Claude review: did not run\n\nExit code `%s`. This is not a pass. Re-run the job, or review by hand.\n\n%s\n' \
    "$marker" "$exit_code" "${reason:+<details><summary>Output</summary>

\`\`\`
$reason
\`\`\`
</details>}")"
else
  body="$(jq -r --arg marker "$marker" '
    def sev_icon: if . == "blocker" then "🟥" elif . == "major" then "🟧" else "🟨" end;
    def verdict_line:
      if .verdict == "pass" then "## Claude review: pass"
      elif .verdict == "changes_requested" then "## Claude review: changes requested"
      else "## Claude review: needs a human" end;
    .structured_output as $v |
    [ $marker,
      ($v | verdict_line),
      "",
      $v.summary,
      "",
      "**Risk tag expected:** `\($v.risk_tag_expected)`  ",
      "**Tests adequate:** \(if $v.tests.adequate then "yes" else "no" end)" +
        (if ($v.tests.gaps | length) > 0 then "\n\nGaps:\n" + ($v.tests.gaps | map("- " + .) | join("\n")) else "" end),
      "",
      (if ($v.findings | length) == 0 then "_No findings._" else
        "### Findings\n\n" + ($v.findings | map(
          "\(.severity | sev_icon) **\(.title)** — `\(.file)`" + (if .line then ":\(.line)" else "" end) + "\n" +
          "  \(.rationale)\n" +
          "  _Suggested fix:_ \(.suggested_fix)"
        ) | join("\n\n")) end),
      "",
      "<sub>Advisory review by headless Claude Code using `.claude/skills/review-pr`. Run `/review-pr <number>` locally to reproduce.</sub>"
    ] | join("\n")' "$file")"
fi

# Upsert: find an existing comment with the marker and edit it, else create.
existing_id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${pr}/comments" --paginate \
  --jq ".[] | select(.body | contains(\"$marker\")) | .id" | head -n1 || true)"

if [ -n "$existing_id" ]; then
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" -f body="$body" >/dev/null
  echo "Updated review comment $existing_id"
else
  gh pr comment "$pr" --body "$body"
  echo "Posted review comment"
fi
