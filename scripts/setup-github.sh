#!/bin/bash
# Applies the repository settings and the `main` branch ruleset (.github/rulesets/main.json).
# Run once after creating the repository, and again whenever the ruleset file changes.
#
#   ./scripts/setup-github.sh                 # repository of the current checkout
#   ./scripts/setup-github.sh owner/name
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
RULESET=".github/rulesets/main.json"
NAME="$(jq -r .name "${RULESET}")"

echo "▸ Repository settings for ${REPO}"
# Squash-only merges keep main linear; branches are deleted after merge.
gh api -X PATCH "repos/${REPO}" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

echo "▸ Ruleset \"${NAME}\""
EXISTING="$(gh api "repos/${REPO}/rulesets" --jq ".[] | select(.name == \"${NAME}\") | .id")"
if [ -n "${EXISTING}" ]; then
  gh api -X PUT "repos/${REPO}/rulesets/${EXISTING}" --input "${RULESET}" --silent
  echo "  updated (id ${EXISTING})"
else
  gh api -X POST "repos/${REPO}/rulesets" --input "${RULESET}" --silent
  echo "  created"
fi

echo "▸ Done: https://github.com/${REPO}/rules"
