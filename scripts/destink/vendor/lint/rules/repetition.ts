// Repetition and dilution metrics (discourse tier, issue #22) — the measurable slice of
// "discourse-level" tells that don't need embeddings or an LLM: content duplication and
// one-point dilution. Two rules live in this file because they share the "count things across
// the whole document" shape and the char n-gram machinery near-duplicate detection needs:
//
//   repetition/near-duplicate  — pairwise near-duplicate UNITS: a paragraph pasted twice, or a
//                                 point restated almost verbatim a few sentences later.
//   repetition/dilution        — one document-level signal: how much of the token stream is
//                                 restated n-grams, a dependency-free proxy for a gzip-style
//                                 compression ratio. node:zlib (or any node builtin) is off-limits
//                                 in rule code — this ships to the browser build.

import type { DocAnalysis, Finding, TropeRule } from "../types.js";

// --- shared: normalized text, character n-grams, cosine ------------------------------------

const normalize = (text: string): string => text.toLowerCase().replace(/\s+/g, " ").trim();

const GRAM_N = 4; // 4-char grams: catches near-verbatim paraphrase without collapsing into a
// bag-of-letters signal the way trigrams do on short units; 5 is stricter but starts missing
// paraphrases that swap one short word ("the"/"a", "is"/"was").

function charGrams(text: string, n = GRAM_N): Map<string, number> {
  const norm = normalize(text);
  const grams = new Map<string, number>();
  for (let i = 0; i + n <= norm.length; i++) {
    const g = norm.slice(i, i + n);
    grams.set(g, (grams.get(g) ?? 0) + 1);
  }
  return grams;
}

function cosine(a: Map<string, number>, b: Map<string, number>): number {
  if (a.size === 0 || b.size === 0) return 0;
  const [small, large] = a.size <= b.size ? [a, b] : [b, a];
  let dot = 0;
  for (const [g, v] of small) {
    const w = large.get(g);
    if (w) dot += v * w;
  }
  if (dot === 0) return 0;
  let normA = 0;
  let normB = 0;
  for (const v of a.values()) normA += v * v;
  for (const v of b.values()) normB += v * v;
  return dot / Math.sqrt(normA * normB);
}

const preview = (text: string, max = 60): string => {
  const t = normalize(text);
  return t.length > max ? `${t.slice(0, max)}…` : t;
};

// --- near-duplicate sentences ----------------------------------------------------------------

// Units shorter than this (after whitespace normalization) are skipped entirely: a 3-word
// fragment ("Not a bug.") shares most of its 4-grams with any other short sentence purely from
// having so few distinct ones to draw from, so comparing them produces noise, not signal.
const MIN_UNIT_LEN = 24;

// Cosine similarity bands, tuned against the fixtures in repetition.test.ts: a paragraph pasted
// twice lands at or near 1.0 and must clear the high band; a tight technical doc that repeats
// *terms* but not *sentences* ("the parser reads the input. the parser resolves names. the
// parser emits code.") must clear NEITHER band — sharing one 6-8 character word out of a
// 24+ character sentence isn't enough 4-gram overlap to reach 0.65.
const EXACT_THRESHOLD = 0.8; // near-verbatim: copy-paste, or copy-paste plus trivial edits
const NEAR_THRESHOLD = 0.65; // paraphrase-level overlap: same content, light rewording

// Comparing every pair of qualifying units is O(n^2); fine at document scale (a few hundred
// units), not fine unbounded. Past this many qualifying units the rule stops adding new
// comparisons and reports the cap instead of stalling the linter on a huge document.
const MAX_COMPARED_UNITS = 500;

export const nearDuplicateRule: TropeRule = {
  id: "repetition/near-duplicate",
  name: "Near-duplicate sentence",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const qualifying = doc.units
      .map((u, index) => ({ u, index }))
      .filter(({ u }) => normalize(u.unit).length >= MIN_UNIT_LEN);

    const capped = qualifying.length > MAX_COMPARED_UNITS;
    const compared = capped ? qualifying.slice(0, MAX_COMPARED_UNITS) : qualifying;
    const profiles = compared.map(({ u }) => charGrams(u.unit));

    // Only the single best earlier match survives per later unit — a sentence that echoes two
    // earlier ones should read as one finding, not a pile-up on the same span.
    const best = new Map<number, { earlier: number; cos: number }>();
    for (let i = 0; i < compared.length; i++) {
      for (let j = i + 1; j < compared.length; j++) {
        const cos = cosine(profiles[i]!, profiles[j]!);
        if (cos < NEAR_THRESHOLD) continue;
        const laterIdx = compared[j]!.index;
        const earlierIdx = compared[i]!.index;
        const current = best.get(laterIdx);
        if (!current || cos > current.cos) best.set(laterIdx, { earlier: earlierIdx, cos });
      }
    }

    const findings: Finding[] = [];
    for (const [laterIdx, { earlier, cos }] of best) {
      const laterUnit = doc.units[laterIdx]!;
      const earlierUnit = doc.units[earlier]!;
      const exact = cos >= EXACT_THRESHOLD;
      const pct = Math.round(cos * 100);
      findings.push({
        ruleId: "repetition/near-duplicate",
        span: laterUnit.span,
        severity: exact ? "high" : "medium",
        message: exact
          ? `near-identical to the sentence at position ${earlier + 1} (${pct}% overlap)`
          : `close paraphrase of the sentence at position ${earlier + 1} (${pct}% overlap)`,
        explanation: `This sentence shares ${pct}% of its character 4-grams with the one at position ${earlier + 1}: “${preview(earlierUnit.unit)}”. ${exact ? "That's copy-paste-level overlap" : "That's enough overlap to read as restating the same point"} — say it once, or make the second pass add something the first one didn't.`,
      });
    }

    if (capped) {
      findings.push({
        ruleId: "repetition/near-duplicate",
        span: { start: 0, end: doc.text.length },
        severity: "low",
        message: `near-duplicate check capped at ${MAX_COMPARED_UNITS} units (document has ${qualifying.length} eligible)`,
        explanation: `Comparing every pair of units is O(n^2); past ${MAX_COMPARED_UNITS} eligible units this rule stops adding comparisons rather than stalling the linter on a large document. Units beyond the cap were not checked against each other for duplication.`,
      });
    }

    return findings;
  },
};

// --- document-level dilution (compression-ratio proxy) ---------------------------------------

// gzip's compression ratio is the obvious repetition proxy, but node:zlib is a Node builtin and
// this package ships to the browser — no zlib, no other node builtin, in rule code. This is the
// dependency-free proxy the issue asks for instead: repeated n-gram MASS over the token stream,
// the same "distinct-n" idea used to score repetitive text generation, inverted into a ratio:
//
//   trigrams = every (token[i], token[i+1], token[i+2]) triple across the WHOLE document's word
//              stream, in document order, lowercased. Unit boundaries are NOT reset between
//              units — a sentence that echoes the tail of the previous one is still restatement.
//   dilution = 1 - (distinct trigrams / total trigrams)
//
// A document that never repeats a 3-word run scores 0. A document that is two copies of the same
// paragraph approaches 1. This also gets "name the most-repeated phrases" for free: whichever
// trigram strings have count > 1 ARE the repeated phrases.
const MIN_TRIGRAMS = 20; // below this the ratio is noise (a ten-word document "repeats" trivially)
const DILUTION_THRESHOLD = 0.25; // >=25% of trigram occurrences restate an earlier one
const TOP_PHRASES = 3;

function trigramsOf(doc: DocAnalysis): string[] {
  const tokens = doc.units.flatMap((u) => u.words.map((w) => w.text.toLowerCase()));
  const grams: string[] = [];
  for (let i = 0; i + 2 < tokens.length; i++) grams.push(`${tokens[i]} ${tokens[i + 1]} ${tokens[i + 2]}`);
  return grams;
}

export const dilutionRule: TropeRule = {
  id: "repetition/dilution",
  name: "Document-level dilution",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const grams = trigramsOf(doc);
    if (grams.length < MIN_TRIGRAMS) return [];

    const counts = new Map<string, number>();
    for (const g of grams) counts.set(g, (counts.get(g) ?? 0) + 1);

    const distinct = counts.size;
    const ratio = 1 - distinct / grams.length;
    if (ratio < DILUTION_THRESHOLD) return [];

    const top = [...counts.entries()]
      .filter(([, c]) => c > 1)
      .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
      .slice(0, TOP_PHRASES)
      .map(([phrase, c]) => `“${phrase}” x${c}`)
      .join(", ");

    const pct = Math.round(ratio * 100);
    return [
      {
        ruleId: "repetition/dilution",
        span: { start: 0, end: doc.text.length },
        severity: "low",
        message: `${pct}% of this document's 3-word runs restate an earlier one`,
        explanation: `Of ${grams.length} overlapping 3-word runs in the document, only ${distinct} are distinct (${pct}% restatement — 1 minus that ratio is what a real compressor would exploit). The most-repeated: ${top || "none over the threshold"}. That's the same idea said again rather than developed — cut the restatement or move the argument forward instead.`,
      },
    ];
  },
};
