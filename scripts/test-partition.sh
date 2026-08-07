#!/usr/bin/env bash
#
# Runs one partition of the test suite with coverage export, and refuses to
# exit 0 unless it can prove the partition actually ran tests.
#
# The proof is the point. `mix test --partition 3` — singular, the flag is
# `--partitions` — prints usage and exits 0 having run nothing, which in CI is
# a green check over a suite that never ran. That is the same shape as #612,
# where the format gate passed for the life of the repo while checking none of
# apps/. Partitioning multiplies the ways to land there: a wrong
# MIX_TEST_PARTITION, a matrix and a `--partitions` count that disagree, a
# filter that empties one partition. So this parses ExUnit's own summary line
# and fails if it is missing or reports zero.
#
# Usage: MIX_TEST_PARTITION=<n> scripts/test-partition.sh <total-partitions>

set -euo pipefail

cd "$(dirname "$0")/.."

partitions="${1:?usage: MIX_TEST_PARTITION=<n> scripts/test-partition.sh <total-partitions>}"
partition="${MIX_TEST_PARTITION:?MIX_TEST_PARTITION must be set}"

# `mix test --partitions` writes the export here, named for the partition, and
# `mix test.coverage` merges every *.coverdata it finds under the umbrella's
# children. The count file lands beside it: the merge job sums the counts so a
# human reading the log sees how many tests the gate actually stood on.
cover_dir="apps/fountain/cover"
coverdata="$cover_dir/$partition.coverdata"
counts="$cover_dir/$partition.tests"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

set +e
mix test --partitions "$partitions" --cover 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

# ExUnit's summary line, e.g. "5 doctests, 3 properties, 837 tests, 0 failures".
# Anchored on the trailing comma so "0 failures" cannot be read as the count.
count=$(grep -oE '[0-9]+ tests?,' "$log" | tail -1 | grep -oE '^[0-9]+' || true)

if [ -z "$count" ]; then
  echo "partition $partition/$partitions: no ExUnit summary line in the output —" >&2
  echo "  the suite did not run, whatever the exit status said." >&2
  exit 1
fi

if [ "$count" -eq 0 ]; then
  echo "partition $partition/$partitions ran 0 tests" >&2
  exit 1
fi

if [ ! -f "$coverdata" ]; then
  echo "partition $partition/$partitions ran $count tests but exported no coverage" >&2
  echo "  (expected $coverdata — without it the merged gate would silently" >&2
  echo "  measure a fraction of the suite and still report a number)." >&2
  exit 1
fi

echo "$count" >"$counts"
echo "partition $partition/$partitions: $count tests, coverage exported to $coverdata"
