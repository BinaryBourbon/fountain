// Anaphora abuse — repeated sentence-initial openings across NEARBY units ("They assume... They
// assume... They assume..."). Tier: "discourse", not "syntactic" — no single sentence carries this
// tell; it only exists as a relationship between units, the same shape as the epic's other
// cross-sentence rules (density counters, the reframe pattern). A single unit can never trigger
// this rule on its own, which is the test for "discourse" over "syntactic" tier.
//
// "Nearby" = a sliding window of WINDOW (5) consecutive units. Two matching openings extend the
// same run as long as no more than WINDOW-1 non-matching (or non-participating) units separate
// them; once a candidate falls outside that window it starts a fresh run instead of joining the
// old one. Three sentences that open a document, a middle section and a conclusion a page apart
// share a word but are not anaphora in the stylistic sense this rule polices — the window is what
// keeps that case clean.
//
// Comparison key, per unit:
//   - lowered units: the subject head's text (subjectHead, ir-query.ts), lowercased. This beats a
//     raw string compare — "The question isn't bold." and "The question is backwards." share a
//     subject even though the copula and complement differ, so two of those in a row correctly
//     read as a deliberate reframe (2 repeats), not anaphora (which needs 3+).
//   - fragments/unparseable units (no Clause to ask): fall back to the unit's own first word,
//     lowercased. A bare function word ("a", "the", "not", "this"...) is ambiguous alone — "Not a
//     bug" and "Not the point" do not open the same way — so those pull in a second word to
//     disambiguate; a content word ("They", "Products") stands on its own.
//
// One finding per maximal run (not one per overlapping window, not one per unit): the run is
// consumed in full once it fires, so the next scan starts past its last member.

import { subjectHead } from "../ir-query.js";
import { spanning } from "../span.js";
import type { DocAnalysis, Finding, TropeRule } from "../types.js";

const WINDOW = 5; // consecutive-unit sliding window — see header comment
const HIGH_AT = 5; // a run this long or longer is more than a tic; bump severity

// Closed-class openers that mean nothing on their own and need a second word to form a real key.
const AMBIGUOUS_OPENERS = new Set(["a", "an", "the", "this", "that", "these", "those", "not"]);

type OpeningKey = { display: string; norm: string };

function firstWords(text: string, n: number): string {
  return text.trim().split(/\s+/).filter(Boolean).slice(0, n).join(" ");
}

function openingKey(unit: DocAnalysis["units"][number]): OpeningKey | null {
  if (unit.clauses && unit.clauses.length > 0) {
    const head = subjectHead(unit.clauses[0]!);
    if (head) return { display: head.text, norm: head.text.toLowerCase() };
  }
  const words = unit.unit.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return null;
  const bareFirst = (words[0] ?? "").toLowerCase().replace(/[^\p{L}\p{N}']/gu, "");
  const n = AMBIGUOUS_OPENERS.has(bareFirst) && words.length > 1 ? 2 : 1;
  const display = firstWords(unit.unit, n);
  return { display, norm: display.toLowerCase() };
}

export const anaphoraRule: TropeRule = {
  id: "anaphora/repeated-opening",
  name: "Anaphora abuse (repeated sentence openings)",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const keys = doc.units.map(openingKey);
    const findings: Finding[] = [];
    let i = 0;
    while (i < keys.length) {
      const k = keys[i];
      if (!k) {
        i++;
        continue;
      }
      const members = [i];
      let last = i;
      for (let j = i + 1; j < keys.length && j - last < WINDOW; j++) {
        const kj = keys[j];
        if (kj && kj.norm === k.norm) {
          members.push(j);
          last = j;
        }
      }
      if (members.length >= 3) {
        const first = doc.units[members[0]!]!;
        const lastUnit = doc.units[members[members.length - 1]!]!;
        const count = members.length;
        findings.push({
          ruleId: "anaphora/repeated-opening",
          span: spanning([first, lastUnit]),
          severity: count >= HIGH_AT ? "high" : "medium",
          message: `${count} sentences in a row open with “${k.display}” — anaphora abuse`,
          explanation: `Repeating the same opening (“${k.display}”) ${count} times in a stretch reads like a drumbeat, not a style — real writers vary how sentences start. Rewrite at least two of these so they don't lead with the same word.`,
        });
        i = last + 1; // consume the whole run — no overlapping windows, no double count
        continue;
      }
      i++;
    }
    return findings;
  },
};
