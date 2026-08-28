// The stink score: weighted findings per 1000 words. This is the number issue #13 exists to
// produce — run any destinking skill's output through the linter and get a score, so "the oracle-
// gated pass beat this skill" is measurable instead of argued.
//
// Weights (why these four numbers, not five, or 1/2/3/4):
//   candidate  0.25  A rule that narrowed a suspect structurally but can't confirm it without
//                     semantics (false ranges, #19 — see the Severity doc comment in types.ts).
//                     It should nudge the score, not swing it: a quarter of the base unit.
//   low        1     The base unit. "One confirmed tell per 1000 words" is the score's natural
//                     scale — a `low` finding is worth exactly one of those.
//   medium     2     A rule staked a firmer claim (usually: density crossed a threshold inside the
//                     rule itself, per engine.ts's doc comment on why rules see the whole document).
//   high       4     Reads as a real problem to a reader, not a rule quibble.
// Doubling per tier (not linear 1/2/3/4) means one `high` outweighs two `medium`s or four `low`s —
// a pile of minor tics shouldn't out-shout one glaring tell, and vice versa.
//
// Word count: whitespace-split tokens of the ORIGINAL source text — `text.trim().split(/\s+/)`.
// Not the tokenizer's word count (drops punctuation-only tokens, splits contractions) and not a
// sum of per-unit word spans (would depend on how units were split). Determinism matters more than
// linguistic purity: one implementation, one number, forever.
//
// The floor: below MIN_WORDS_FOR_SCORE, "per 1000 words" amplifies noise — a single `high` finding
// in a 20-word fragment would score 200. Dividing by max(words, floor) instead of words keeps short
// inputs from producing scores that can't be compared against real documents.

import type { Finding, Severity, TropeTier } from "./types.js";

export const SEVERITY_WEIGHT: Readonly<Record<Severity, number>> = {
  candidate: 0.25,
  low: 1,
  medium: 2,
  high: 4,
};

export const MIN_WORDS_FOR_SCORE = 100;

// Whitespace-split tokens of `text`. See the module doc comment for why this definition (not the
// tokenizer's) is the one the score uses.
export function countWords(text: string): number {
  const trimmed = text.trim();
  return trimmed === "" ? 0 : trimmed.split(/\s+/).length;
}

// Every tier, always present in the output (0 when a tier had no findings) so byTier has the same
// shape regardless of input — a consumer can destructure it without an existence check.
export const TIERS: readonly TropeTier[] = ["lexical", "syntactic", "formatting", "discourse"];

export type ScoreBreakdown = {
  total: number;
  byTier: Readonly<Record<TropeTier, number>>;
  byRule: Readonly<Record<string, number>>;
};

// Weighted findings per 1000 words, overall and split by tier and by rule. `ruleTier` maps a
// finding's ruleId back to its tier — findings don't carry tier themselves (see types.ts), so the
// caller supplies the lookup (built from whatever TropeRule[] was actually run) rather than this
// module importing the registry, which would make score.ts untestable without it.
export function scoreFindings(
  findings: readonly Finding[],
  wordCount: number,
  ruleTier: (ruleId: string) => TropeTier | undefined,
): ScoreBreakdown {
  const denom = Math.max(wordCount, MIN_WORDS_FOR_SCORE);
  const per1000 = (weight: number): number => (weight / denom) * 1000;

  const byTierWeight: Partial<Record<TropeTier, number>> = {};
  const byRuleWeight: Record<string, number> = {};
  let totalWeight = 0;

  for (const f of findings) {
    const w = SEVERITY_WEIGHT[f.severity];
    totalWeight += w;
    byRuleWeight[f.ruleId] = (byRuleWeight[f.ruleId] ?? 0) + w;
    const tier = ruleTier(f.ruleId);
    if (tier) byTierWeight[tier] = (byTierWeight[tier] ?? 0) + w;
  }

  const byTier = {} as Record<TropeTier, number>;
  for (const t of TIERS) byTier[t] = per1000(byTierWeight[t] ?? 0);

  // Sorted by ruleId so the key order — and thus JSON.stringify output — never depends on finding
  // order, which itself depends only on span position (engine.ts), not on rule registration order.
  const byRule: Record<string, number> = {};
  for (const id of Object.keys(byRuleWeight).sort()) byRule[id] = per1000(byRuleWeight[id]!);

  return { total: per1000(totalWeight), byTier, byRule };
}
