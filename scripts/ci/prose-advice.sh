#!/usr/bin/env bash
# Wording advice stays visible without blocking fixes or flooding the log.
# Installation/setup remain separate, blocking workflow steps.
set -uo pipefail
name=${1:?usage: prose-advice.sh name command [args...]}
shift
report_dir="${RUNNER_TEMP:-/tmp}/prose-advice"
mkdir -p "$report_dir"
report="$report_dir/$name.txt"
"$@" > "$report" 2>&1
status=$?
head -60 "$report"
if [ "$(wc -l < "$report")" -gt 60 ]; then
  echo 'Output truncated; the prose-advice artifact contains the full report.'
fi
if [ "$status" -ne 0 ]; then
  echo "::warning::$name reported wording advice or a linter error (exit $status); see the prose-advice artifact."
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- $name: exit $status (advisory). Full output is in the prose-advice artifact." >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
