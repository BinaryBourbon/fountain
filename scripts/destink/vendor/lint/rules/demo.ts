// DEMO RULE — the reference implementation. It is here to prove the loop end-to-end (text in,
// located findings out, deterministic) and to be the thing a new rule gets copied from. Filler
// intensifiers are not one of the tropes in the epic; wave 2 should delete this entry from
// registry.ts once real rules land, and keep the tests that pin the runner's semantics.
//
// It demonstrates the three things every rule does:
//   1. locate — findings carry spans into doc.text, taken from the words the analysis already
//      mapped, so nothing re-tokenizes and every span slices back to the exact surface form.
//   2. count first, judge second — the whole document is in hand, so severity comes from DENSITY.
//      One "very" is a word; five is a tic. This is the thing a sentence-at-a-time judge can't do.
//   3. teach — `message` names the pattern in a few words, `explanation` says why it reads as a
//      tell and what to do instead, in the voice of free.ts's hints: concrete, second person,
//      one example, no lecture.

import type { DocAnalysis, Finding, TropeRule } from "../types.js";

const INTENSIFIERS = new Set(["very", "really", "quite", "extremely", "incredibly", "truly"]);

// Below this the word is just a word; at or above it the repetition is the tell.
const PATTERN_AT = 3;

export const demoIntensifierRule: TropeRule = {
  id: "demo/intensifier",
  name: "Filler intensifier (demo)",
  tier: "lexical",
  detect(doc: DocAnalysis): Finding[] {
    const hits = doc.units.flatMap((u) => u.words.filter((w) => INTENSIFIERS.has(w.text.toLowerCase())));
    if (hits.length === 0) return [];
    const dense = hits.length >= PATTERN_AT;
    return hits.map((w) => ({
      ruleId: "demo/intensifier",
      span: w.span,
      severity: dense ? ("medium" as const) : ("low" as const),
      message: dense ? `“${w.text}” — ${hits.length} filler intensifiers in this piece` : `“${w.text}” adds emphasis, not meaning`,
      explanation: dense
        ? `You lean on ${hits.length} of these (very, really, quite…). Once is a shrug; this often it reads as padding. Cut them all, then put the emphasis back with a stronger word — “very fast” becomes “blistering”.`
        : `“${w.text}” tells the reader to feel more without giving them more. Try the sentence without it — if nothing is lost, leave it out.`,
    }));
  },
};
