# Merge

Autonomous merge agent for GitHub repos. Part of [MakerSuite](https://github.com/derrybirkett/deltado).

Polls every 30 minutes for PRs labelled `merge/ready`. After a 24-hour review window, runs an AI safety check, then merges or blocks.

## How it works

1. Apply `merge/ready` to a PR (manually, or automatically via Council)
2. 24-hour review window begins — remove the label at any time to cancel
3. After 24h: CI must be green, no merge conflicts, AI must approve
4. On approval: PR is squash-merged and labelled accordingly
5. On block: `merge/blocked` is applied with an explanation — remove it and re-apply `merge/ready` to retry

## Installation

```bash
# 1. Add submodule
git submodule add https://github.com/derrybirkett/merge merge

# 2. Add workflow
cp merge/.github/workflows/merge.yml .github/workflows/merge.yml

# 3. One-time setup (creates labels, optionally patches Council)
bash merge/scripts/setup.sh
```

**Required secret:** `ANTHROPIC_API_KEY` (already set if using Delta or Council)

## Labels

| Label | Meaning |
|---|---|
| `merge/ready` | PR is queued — apply to start the 24h window |
| `merge/blocked` | AI blocked the merge — human review required |

## Configuration

Set `MERGE_STRATEGY` as a GitHub Actions repository variable to control merge method.
Options: `squash` (default), `rebase`, `merge`.

## MakerSuite

Merge is designed to work standalone, but pairs with:
- [Delta](https://github.com/derrybirkett/delta) — builds features autonomously
- [Council](https://github.com/derrybirkett/council) — AI CTO review gate

When all three are installed, `setup.sh` patches Council to apply `merge/ready` automatically after `council/approved`, completing the fully autonomous loop: **Delta builds → Council reviews → Merge ships**.
