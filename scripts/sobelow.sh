#!/usr/bin/env bash
# Sobelow scan covering core AND ee/ (decisions/0010).
#
# Sobelow scans a single Phoenix app root: it needs root/mix.exs for the app
# name and a router among the scanned files, so it cannot scan ee/ directly
# (no mix.exs, no router). Instead we assemble a throwaway merged tree —
# apps/fountain's lib with ee/lib overlaid (their file sets are disjoint by
# construction; the move was pure renames) — and point sobelow at that. This
# reproduces the exact pre-#472 scan, when the ee files still lived in core.
#
# Callers: `mix precommit` (root mix.exs) and .github/workflows/ci.yml.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scan="$(mktemp -d)"
trap 'rm -rf "$scan"' EXIT

cp "$root/apps/fountain/mix.exs" "$scan/mix.exs"
cp "$root/apps/fountain/.sobelow-conf" "$scan/.sobelow-conf"
cp -R "$root/apps/fountain/lib" "$scan/lib"
# tar pipe rather than cp: portable directory merge on both BSD/macOS and GNU
tar -C "$root/ee/lib" -cf - . | tar -C "$scan/lib" -xf -

# Guard the "disjoint by construction" assumption: a core file and an ee file
# at the same path would silently shadow each other in the merged tree.
dupes="$(cd "$root/apps/fountain/lib" && find . -type f | sort >"$scan/.core-files" && cd "$root/ee/lib" && find . -type f | sort | comm -12 "$scan/.core-files" -)"
if [ -n "$dupes" ]; then
  echo "sobelow.sh: path collision between apps/fountain/lib and ee/lib:" >&2
  echo "$dupes" >&2
  exit 1
fi

cd "$root/apps/fountain"
exec mix sobelow --root "$scan" --config
