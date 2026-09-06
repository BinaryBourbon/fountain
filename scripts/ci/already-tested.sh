#!/usr/bin/env bash
# Reuse only a successful PR run's recorded checkout tree. The API's head_sha
# identifies the PR, but checkout normally tests its synthetic merge commit.
# Missing/expired artifacts, old workflows, and API failures all run full CI.
set -uo pipefail

tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo 'skip=false' >> "$GITHUB_OUTPUT"
if [[ ! $tree =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Could not resolve the checkout tree; running full CI.'
  exit 0
fi

heads=$(gh api "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" \
  --jq '.[] | select(.merged_at != null) | .head.sha' 2>/dev/null || true)

for head in $heads; do
  runs=$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?head_sha=${head}&event=pull_request&status=success&per_page=20" \
    --jq '.workflow_runs[].id' 2>/dev/null || true)
  for run in $runs; do
    mkdir -p "$tmp/$run"
    if ! gh run download "$run" --repo "$GITHUB_REPOSITORY" \
      --name tested-tree --dir "$tmp/$run" 2>/dev/null; then
      continue
    fi
    # Require exactly the expected bytes, not a partial match or a sourced file.
    if printf '%s\n' "$tree" | cmp -s - "$tmp/$run/tested-tree.txt"; then
      echo 'skip=true' >> "$GITHUB_OUTPUT"
      echo "This tree passed in PR CI run $run."
      echo "Tested by https://github.com/${GITHUB_REPOSITORY}/actions/runs/${run}" >> "$GITHUB_STEP_SUMMARY"
      exit 0
    fi
  done
done
echo 'No successful PR run proves this checkout tree; running full CI.'
