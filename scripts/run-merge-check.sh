#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_STRATEGY="${MERGE_STRATEGY:-squash}"
REVIEW_WINDOW_SECONDS=$((24 * 3600))

echo "=== Merge Agent Check — $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

# Ensure labels exist
gh label create "merge/ready"   --color "0075ca" --description "Queued for autonomous merge"  2>/dev/null || true
gh label create "merge/blocked" --color "e11d48" --description "Merge blocked by Merge agent" 2>/dev/null || true

process_pr() {
  local pr="$1"
  echo ""
  echo "--- PR #${pr} ---"

  # Skip if already blocked
  local is_blocked
  is_blocked=$(gh pr view "$pr" --json labels \
    --jq '[.labels[].name] | contains(["merge/blocked"])' 2>/dev/null || echo "false")
  if [[ "$is_blocked" == "true" ]]; then
    echo "PR #${pr}: already blocked, skipping"
    return 0
  fi

  # Get timestamp when merge/ready was most recently applied (paginate all events)
  local labeled_at
  labeled_at=$(gh api --paginate "repos/{owner}/{repo}/issues/${pr}/events" 2>/dev/null \
    | jq -rs '[.[][] | select(.event == "labeled" and .label.name == "merge/ready")] | max_by(.created_at) | .created_at // empty' \
    || echo "")

  if [[ -z "$labeled_at" ]]; then
    echo "PR #${pr}: cannot determine merge/ready timestamp, skipping"
    return 0
  fi

  # Elapsed seconds since label applied (uses Linux date — available in GitHub Actions)
  local labeled_epoch now_epoch elapsed
  labeled_epoch=$(date -d "$labeled_at" +%s)
  now_epoch=$(date +%s)
  elapsed=$(( now_epoch - labeled_epoch ))

  if [[ "${MERGE_TEST_MODE:-false}" != "true" ]] && (( elapsed < REVIEW_WINDOW_SECONDS )); then
    local remaining_hours
    remaining_hours=$(( (REVIEW_WINDOW_SECONDS - elapsed) / 3600 ))
    echo "PR #${pr}: ${remaining_hours}h remaining in review window, skipping"
    return 0
  fi
  [[ "${MERGE_TEST_MODE:-false}" == "true" ]] && echo "PR #${pr}: MERGE_TEST_MODE active — bypassing review window"

  # Check CI status
  local ci_status
  ci_status=$(gh pr view "$pr" --json statusCheckRollup \
    --jq '.statusCheckRollup // [] | if length == 0 then "none" elif any(.[]; (.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT") or (.__typename == "StatusContext" and (.state == "FAILURE" or .state == "ERROR"))) then "failure" elif all(.[]; (.__typename == "CheckRun" and .status == "COMPLETED") or (.__typename == "StatusContext" and .state == "SUCCESS")) then "success" else "pending" end')

  if [[ "$ci_status" == "failure" ]]; then
    gh pr comment "$pr" --body "### Merge Agent

CI is failing — not merging until all checks are green.

*Fix CI, then remove and re-apply \`merge/ready\` to reset the 24h window.*"
    echo "PR #${pr}: CI failing, skipping"
    return 0
  fi

  if [[ "$ci_status" == "pending" ]]; then
    echo "PR #${pr}: CI still running, will retry next tick"
    return 0
  fi

  # Check mergeability
  local mergeable
  mergeable=$(gh pr view "$pr" --json mergeable --jq '.mergeable')

  if [[ "$mergeable" == "CONFLICTING" ]]; then
    gh pr comment "$pr" --body "### Merge Agent

Cannot merge — conflicts with \`main\`. Please rebase and resolve conflicts, then re-apply \`merge/ready\`."
    gh pr edit "$pr" --remove-label "merge/ready"
    echo "PR #${pr}: merge conflicts, skipping"
    return 0
  fi

  if [[ "$mergeable" == "UNKNOWN" ]]; then
    echo "PR #${pr}: mergeability unknown (GitHub computing), will retry next tick"
    return 0
  fi

  # Run AI judgment
  local prompt pr_title pr_body pr_diff readme_content pkg_content elapsed_hours
  prompt=$(cat "${REPO_ROOT}/merge/advisors/merge/prompt.md")
  pr_title=$(gh pr view "$pr" --json title --jq '.title')
  pr_body=$(gh pr view "$pr" --json body --jq '.body // ""')
  pr_diff=$(gh pr diff "$pr")
  readme_content=$(git show origin/main:README.md 2>/dev/null || echo "(no README)")
  pkg_content=$(git show origin/main:package.json 2>/dev/null || echo "(no package.json)")
  elapsed_hours=$(( elapsed / 3600 ))

  local verdict prompt_file
  prompt_file=$(mktemp)
  echo "$prompt" > "$prompt_file"
  verdict=$(claude --print --model haiku --system-prompt-file "$prompt_file" <<EOF
## PR #${pr}: ${pr_title}

### Description
${pr_body}

### Review window
${elapsed_hours} hours elapsed (minimum 24h window has been respected)

### Current main branch context

**README.md:**
${readme_content}

**package.json:**
${pkg_content}

### PR Diff
${pr_diff}
EOF
)
  rm -f "$prompt_file"

  echo "AI verdict for PR #${pr}:"
  echo "$verdict"

  # Parse first word: must be MERGE or BLOCK
  local first_word
  first_word=$(echo "$verdict" | head -1 | awk '{print toupper($1)}' | tr -d '[:punct:]')

  if [[ "$first_word" == "MERGE" ]]; then
    local merge_flag
    case "$MERGE_STRATEGY" in
      squash) merge_flag="--squash" ;;
      rebase) merge_flag="--rebase" ;;
      merge)  merge_flag="--merge"  ;;
      *)
        echo "PR #${pr}: unknown MERGE_STRATEGY '${MERGE_STRATEGY}', defaulting to squash"
        merge_flag="--squash"
        ;;
    esac

    local merged=false
    if gh pr merge "$pr" "$merge_flag"; then
      merged=true
    fi

    if [[ "$merged" == "true" ]]; then
      gh pr comment "$pr" --body "### Merge Agent

Merged after ${elapsed_hours}h review window using \`${MERGE_STRATEGY}\` strategy.

**AI assessment:**
${verdict}"
      echo "PR #${pr}: merged"
    else
      gh pr edit "$pr" --add-label "merge/blocked" --remove-label "merge/ready"
      gh pr comment "$pr" --body "### Merge Agent

Failed to execute merge — blocked to prevent retry loop.

Possible causes: branch protection rules, required reviews, or insufficient workflow permissions.

Remove \`merge/blocked\` and re-apply \`merge/ready\` to retry. If permissions are the issue, check:
*Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests*"
      echo "PR #${pr}: merge execution failed, applied merge/blocked"
    fi

  elif [[ "$first_word" == "BLOCK" ]]; then
    gh pr edit "$pr" --add-label "merge/blocked" --remove-label "merge/ready"
    gh pr comment "$pr" --body "### Merge Agent

Merge blocked. Remove \`merge/blocked\` and re-apply \`merge/ready\` to retry.

**AI assessment:**
${verdict}"
    echo "PR #${pr}: blocked"

  else
    # Ambiguous response — safe default is block
    gh pr edit "$pr" --add-label "merge/blocked" --remove-label "merge/ready"
    gh pr comment "$pr" --body "### Merge Agent

Merge blocked — AI response was ambiguous. Human review required.

Remove \`merge/blocked\` and re-apply \`merge/ready\` to retry.

**AI response:**
${verdict}"
    echo "PR #${pr}: ambiguous verdict, blocked for safety"
  fi
}

# Query open PRs with merge/ready label
prs=$(gh pr list \
  --label "merge/ready" \
  --state open \
  --json number \
  --jq '.[].number')

if [[ -z "$prs" ]]; then
  echo "No PRs queued for merge."
  exit 0
fi

while IFS= read -r pr_number; do
  process_pr "$pr_number" || echo "PR #${pr_number}: unexpected error during processing, skipping"
done <<< "$prs"

echo ""
echo "=== Merge check complete ==="
