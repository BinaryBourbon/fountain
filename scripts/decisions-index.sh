#!/usr/bin/env bash
# Regenerate decisions/index.md from ADR frontmatter (OKF spec §8).
#
# `okf index` would do this too, but it sorts by title and truncates the
# description; ADRs read better in number order with their status beside them.
# CI runs this and fails if the committed index differs (see
# .github/workflows/decisions.yml), so edit frontmatter, not the index.
set -euo pipefail
cd "$(dirname "$0")/../decisions"

{
  cat <<'EOF'
# Decisions

Architecture Decision Records for Fountain, one per file, numbered in the
order they were opened. Every file carries OKF frontmatter (`type`, `status`,
`adr_status`, `description`, `verified`, `stale_after`); `okf validate .`
checks it and `okf backlinks . <id>` shows what depends on a decision.
`adr_status` is the ADR's own lifecycle (Proposed / Accepted / Partially
accepted / Superseded by NNNN); `status` is the OKF lifecycle derived from it
(draft / stable / deprecated). Gaps in the numbering are ADRs still on open
branches.

## ADRs

| # | Title | ADR status | Verified | Stale after | Description |
|---|-------|------------|----------|-------------|-------------|
EOF
  for f in [0-9][0-9][0-9][0-9]-*.md; do
    awk -v file="$f" '
      function unq(s) { sub(/^"/, "", s); sub(/"$/, "", s); gsub(/\\"/, "\"", s); return s }
      NR == 1 && $0 != "---" { exit 1 }
      NR > 1 && $0 == "---" { done = 1 }
      !done && /^adr: /         { adr = unq(substr($0, 6)) }
      !done && /^title: /       { title = unq(substr($0, 8)) }
      !done && /^adr_status: /  { st = unq(substr($0, 13)) }
      !done && /^description: / { desc = unq(substr($0, 14)) }
      !done && /^verified: /    { v = "yes" }
      !done && /^stale_after: / { stale = $2 }
      END {
        gsub(/\|/, "\\|", title); gsub(/\|/, "\\|", desc)
        printf "| %s | [%s](%s) | %s | %s | %s | %s |\n", adr, title, file, st, (v ? v : "no"), (stale ? stale : ""), desc
      }' "$f"
  done
} > index.md
