// The stable JSON report: findings + score + per-rule/per-tier counts, in a shape stable enough
// for external tooling. This is a public contract — the eventual out-of-repo LLM patch loop (the
// point of epic #28) parses this JSON, not the TropeRule/Finding types directly, so:
//
//   - Key order is explicit. Every object below is constructed field-by-field in the order shown
//     here, never produced by spreading a Finding or by `Object.fromEntries` over an unsorted map.
//     JSON.stringify walks an object's own keys in insertion order, so construction order IS output
//     order — this is what makes two runs over the same input byte-identical.
//   - Nothing here may vary between two runs over the same input: no timestamps, no absolute paths,
//     no environment-dependent values (hostnames, cwd, process.version). Determinism and privacy
//     both fall out of that one rule.
//   - `version` is the schema version. Bump it when a key is removed, renamed, or changes meaning.
//     Adding a new optional key is not a breaking change and does not require a bump.
//
// Schema (version 1):
//   {
//     version: 1,
//     wordCount: number,                  // countWords(source) — see score.ts
//     score: {
//       total: number,                    // weighted findings per 1000 words
//       byTier: { lexical, syntactic, formatting, discourse: number },
//       byRule: { [ruleId]: number },     // keys sorted ascending
//     },
//     counts: {
//       findings: number,                 // findings.length, unweighted
//       bySeverity: { candidate, low, medium, high: number },
//       byTier: { lexical, syntactic, formatting, discourse: number },
//       byRule: { [ruleId]: number },     // keys sorted ascending
//     },
//     findings: [{
//       ruleId: string,
//       tier: "lexical" | "syntactic" | "formatting" | "discourse" | null,  // null iff ruleId
//         // is not in the rule set the report was built from (should not happen in practice —
//         // engine.ts only calls detect() on rules it was given — but the field stays nullable
//         // rather than lying with a made-up tier if it ever does)
//       severity: "candidate" | "low" | "medium" | "high",
//       span: { start: number, end: number },  // half-open [start, end) into the source text
//       message: string,
//       explanation: string,
//     }],                                 // same order as LintResult.findings (engine.ts):
//                                          // span.start asc, span.end asc, ruleId asc
//     errors: [{ ruleId: string, message: string }],  // rule failures (engine.ts's RuleError),
//                                          // minus the raw `error` value — not guaranteed
//                                          // JSON-safe or stable across runs, console-only there
//   }

import type { Finding, Severity, TropeRule, TropeTier } from "./types.js";
import type { RuleError } from "./engine.js";
import { countWords, scoreFindings, TIERS, type ScoreBreakdown } from "./score.js";

const SEVERITIES: readonly Severity[] = ["candidate", "low", "medium", "high"];

export type ReportFinding = {
  ruleId: string;
  tier: TropeTier | null;
  severity: Severity;
  span: { start: number; end: number };
  message: string;
  explanation: string;
};

export type ReportError = { ruleId: string; message: string };

export type Report = {
  version: 1;
  wordCount: number;
  score: ScoreBreakdown;
  counts: {
    findings: number;
    bySeverity: Readonly<Record<Severity, number>>;
    byTier: Readonly<Record<TropeTier, number>>;
    byRule: Readonly<Record<string, number>>;
  };
  findings: ReportFinding[];
  errors: ReportError[];
};

const tierLookup = (rules: readonly TropeRule[]): ((ruleId: string) => TropeTier | undefined) => {
  const byId = new Map(rules.map((r) => [r.id, r.tier]));
  return (ruleId) => byId.get(ruleId);
};

// Sorted-key count map, built the same way score.ts sorts byRule weights — a shared helper would
// save four lines and cost the reader a jump between files for something this small.
function countsByRule(items: readonly { ruleId: string }[]): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const item of items) counts[item.ruleId] = (counts[item.ruleId] ?? 0) + 1;
  const sorted: Record<string, number> = {};
  for (const id of Object.keys(counts).sort()) sorted[id] = counts[id]!;
  return sorted;
}

// Build the stable report from a lint run. `rules` is whatever TropeRule[] actually ran (normally
// `enabledRules()`'s result) — needed to look up each finding's tier, since Finding itself doesn't
// carry one (types.ts).
export function buildReport(
  text: string,
  findings: readonly Finding[],
  errors: readonly RuleError[],
  rules: readonly TropeRule[],
): Report {
  const tierOf = tierLookup(rules);
  const wordCount = countWords(text);
  const score = scoreFindings(findings, wordCount, tierOf);

  const bySeverity = {} as Record<Severity, number>;
  for (const s of SEVERITIES) bySeverity[s] = 0;
  const byTier = {} as Record<TropeTier, number>;
  for (const t of TIERS) byTier[t] = 0;
  for (const f of findings) {
    bySeverity[f.severity]++;
    const tier = tierOf(f.ruleId);
    if (tier) byTier[tier]++;
  }

  return {
    version: 1,
    wordCount,
    score,
    counts: {
      findings: findings.length,
      bySeverity,
      byTier,
      byRule: countsByRule(findings),
    },
    findings: findings.map((f) => ({
      ruleId: f.ruleId,
      tier: tierOf(f.ruleId) ?? null,
      severity: f.severity,
      span: { start: f.span.start, end: f.span.end },
      message: f.message,
      explanation: f.explanation,
    })),
    errors: errors.map((e) => ({ ruleId: e.ruleId, message: e.message })),
  };
}
