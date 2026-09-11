#!/usr/bin/env bash
# Reuse only a successful run's recorded checkout tree. The API's head_sha
# identifies the PR, but checkout normally tests its synthetic merge commit.
# Missing/expired artifacts, old workflows, and API failures all run full CI.
#
# Two events reach this probe, and each has its own candidate runs:
#
#   merge_group — the queue is about to test a tree. When that tree is already
#                 exactly a PR run's tree (the PR was up to date and the group
#                 holds it alone) the queue run is pure duplication. A batched
#                 group combines trees that no PR run ever had, so the
#                 comparison below fails on its own and the full suite runs.
#   push        — main. The queue tested this tree under a
#                 `gh-readonly-queue/<base>/pr-<number>-<sha>` branch moments
#                 ago, so that run is the proof; a PR merged outside the queue
#                 still reaches its own `pull_request` run, as before.
#
# Tree equality stays the single safety property either way: a candidate run is
# only a shortcut when it recorded this exact tree.
set -uo pipefail

event=${GITHUB_EVENT_NAME:-push}
tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null || true)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo 'skip=false' >> "$GITHUB_OUTPUT"
if [[ ! $tree =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Could not resolve the checkout tree; running full CI.'
  exit 0
fi

api="repos/${GITHUB_REPOSITORY}"
numbers=""
heads=""

if [[ $event == merge_group ]]; then
  # refs/heads/gh-readonly-queue/main/pr-1234-<base sha>
  numbers=$(printf '%s\n' "${GITHUB_REF:-}" | grep -oE 'pr-[0-9]+-' | tr -dc '0-9\n' || true)
  for number in $numbers; do
    heads+=" $(gh api "${api}/pulls/${number}" --jq '.head.sha' 2>/dev/null || true)"
  done
else
  merged=$(gh api "${api}/commits/${GITHUB_SHA}/pulls" \
    --jq '.[] | select(.merged_at != null) | "\(.number) \(.head.sha)"' 2>/dev/null || true)
  numbers=$(printf '%s\n' "$merged" | cut -d' ' -f1)
  heads=$(printf '%s\n' "$merged" | cut -d' ' -f2)
fi

candidates=""
for head in $heads; do
  [[ $head =~ ^[0-9a-f]{40}$ ]] || continue
  candidates+=" $(gh api "${api}/actions/workflows/ci.yml/runs?head_sha=${head}&event=pull_request&status=success&per_page=20" \
    --jq '.workflow_runs[].id' 2>/dev/null || true)"
done

# Only main looks for a queue run: inside the queue, the run being decided is
# the merge_group run itself.
if [[ $event != merge_group ]]; then
  for number in $numbers; do
    [[ $number =~ ^[0-9]+$ ]] || continue
    candidates+=" $(gh api "${api}/actions/workflows/ci.yml/runs?event=merge_group&status=success&per_page=50" \
      --jq ".workflow_runs[] | select(.head_branch | test(\"/pr-${number}-\")) | .id" 2>/dev/null || true)"
  done
fi

for run in $candidates; do
  [[ $run =~ ^[0-9]+$ ]] || continue
  mkdir -p "$tmp/$run"
  if ! gh run download "$run" --repo "$GITHUB_REPOSITORY" \
    --name tested-tree --dir "$tmp/$run" 2>/dev/null; then
    continue
  fi
  # Require exactly the expected bytes, not a partial match or a sourced file.
  if printf '%s\n' "$tree" | cmp -s - "$tmp/$run/tested-tree.txt"; then
    echo 'skip=true' >> "$GITHUB_OUTPUT"
    echo "This tree passed in CI run $run."
    echo "Tested by https://github.com/${GITHUB_REPOSITORY}/actions/runs/${run}" >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
done
echo 'No successful run proves this checkout tree; running full CI.'
