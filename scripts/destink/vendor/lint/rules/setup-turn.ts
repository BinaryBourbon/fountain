// THE SETUP AND THE TURN (#34) — a bare noun phrase presented as a sentence, answered by a short
// beat that takes it away. "3 rules. And none you set." "A new framework. And nobody asked for it."
// "Beautiful documentation. None of it true." "Six weeks of planning. Not one line shipped."
//
// The tell is the SETUP, not what fills it. The first beat is not a sentence — it names a thing and
// stops, which is a stage direction rather than a claim. The second beat voids the thing before the
// reader has been told anything about it. Two beats in there is still nothing to agree or disagree
// with, and that is the formula working: it buys attention with a frame and pays it off with a
// reversal, and no argument is ever made. It reads as written-for-the-feed because that is the unit
// the feed rewards.
//
// This rule shipped first as "quantity-hook", keyed on a number in the setup slot ("3 rules.",
// "Twelve engineers."). That was reading the filler for the form. A count is the most common thing
// people put in a setup slot and it is not what makes it one — dropping the requirement took the
// rule from 5 of 14 collected specimens to 14 of 14, and the nine it had been missing are the same
// formula with a noun phrase instead of a number ("Endless meetings. No decisions."). The count is
// kept only as a label in the message, because "a bare count" is worth naming when it is there.
//
// --- why discourse/punchy-fragments does not cover this ---
//
// It fires on four of the fourteen specimens, and the four are arbitrary. punchy-fragments needs a
// run of >= 2 consecutive units with outcome === "fragment", and the turn usually has a verb in it,
// so document.ts calls it "unparseable" and fragments.ts (correctly, per its own header) refuses to
// treat unparseables as fragments:
//
//   "3 rules. And none you set."                  "And none you set" -> unparseable  (silent)
//   "A thousand dashboards. Nobody reading them."                    -> unparseable  (silent)
//   "Six weeks of planning. Not one line shipped."                   -> unparseable  (silent)
//   "Endless meetings. No decisions."             both verbless      -> FIRES
//
// So coverage is decided by whether the turn happens to contain a verb, which has nothing to do
// with the trope. And when it does fire it hands the reader the wrong note — "choppy staccato
// rhythm, let some of these be full sentences" is advice about rhythm, and the problem here is a
// frame that never becomes a claim. This rule reads the shape, so the verb in the turn stops
// mattering.
//
// --- the four tests ---
//
//   setup is a noun phrase   2..5 words, no finite verb of its own, and not opening on a
//                            preposition or a subordinator (those make it a stranded modifier, not
//                            a frame) or on a voider (that is rules/fragments.ts's countdown).
//   setup is verbless        crude lexical evidence, NOT the parse: the rule-based chunker lowers
//                            "Twelve engineers" as a clause (reading the noun as a verb) while
//                            calling "3 rules" a fragment, so keying on outcome would make coverage
//                            depend on that coin-flip. See hasVerbEvidence.
//   the turn voids           a quantificational negator near the front of the second beat. This is
//                            the test that makes the rule safe to fire on a SINGLE instance, and it
//                            is why the disproportion variant is out (below).
//   both beats stay short    past these lengths a beat is a sentence, and a sentence is not a beat.
//
// --- what is deliberately NOT here: the disproportion variant ---
//
// "Four hours. One line of code." and "5 minutes. That's all it took." are the same formula with a
// turn that diminishes instead of voiding. They are left out because nothing structural separates
// them from an ingredient list or a spec sheet:
//
//   "Four hours. One line of code."     noun-phrase beat, noun-phrase beat
//   "2 eggs. 1 cup flour."              noun-phrase beat, noun-phrase beat
//
// Telling those apart needs to know four hours is a lot and one line is a little, which is
// semantics this rule cannot see. Requiring an explicit voider is the rule, not a threshold on it.
// If the variant is ever wanted it belongs behind "candidate" severity (see types.ts).

import type { DocAnalysis, Finding, Severity, TropeRule, UnitAnalysis, WordSpan } from "../types.js";
import { makeContext, suppressed, type Context } from "./fragments.js";
import { spanning } from "../span.js";

const RULE_ID = "discourse/setup-turn";

// Lengths. The setup is a noun phrase ("A whole quarter of work" is the longest specimen at 5); the
// turn runs a word or two longer because it may carry a verb ("Nobody could answer it").
const MAX_SETUP_WORDS = 5;
const MAX_TURN_WORDS = 6;

// --- the setup beat ---
//
// Cardinals and the digit test below no longer GATE anything — a setup is a noun phrase whether or
// not it opens on a number. They survive only to label the finding, because "a bare count answered
// by a void" is a more useful sentence to hand a reader than the generic one when the count is
// actually there. See isQuantitySetup at the bottom.

// Spelled cardinals. Ordinals are absent on purpose: "First rule. None you set." is a different
// (and ordinary) shape — an ordinal enumerates, it does not quantify.
const CARDINALS = new Set([
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
  "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
  "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
  "hundred", "thousand", "million", "billion", "dozen",
]);

// "a thousand dashboards", "a dozen meetings" — the article carries no quantity on its own, so it
// only counts when the next token does. Kept to the big round ones: "a rule" is not a quantity.
const ARTICLE_QUANTIFIABLE = new Set(["dozen", "hundred", "thousand", "million", "billion"]);

const DIGIT_QUANTITY = /^\d/; // 3, 40%, 1,000 — anything opening with a digit

// Crude finite-verb evidence, the same idiom and for the same reason as contrast-tail.ts's: this
// rule runs on the parser-free path too, where no POS tags exist, and every word here can only be a
// verb. It is what keeps "Twelve engineers are idle." out of the count beat — and it is needed
// because the parse alone is not reliable on a bare noun phrase (the rule-based chunker lowers
// "Twelve engineers" as a clause, reading the noun "engineers" as a verb, while calling "3 rules" a
// fragment; keying on outcome would make coverage depend on that coin-flip).
const FINITE_VERBS = new Set([
  "is", "are", "was", "were", "am", "be", "been", "being",
  "has", "have", "had", "does", "do", "did",
  "will", "would", "can", "could", "shall", "should", "may", "might", "must",
]);

const isWordToken = (w: WordSpan): boolean => /[\p{L}\p{N}]/u.test(w.text);

const wordsOf = (u: UnitAnalysis): string[] => u.words.filter(isWordToken).map((w) => w.text);

const isQuantity = (w: string): boolean => DIGIT_QUANTITY.test(w) || CARDINALS.has(w.toLowerCase());

// Label only — see the note above CARDINALS. True when the setup opens on a number, so the finding
// can say "a bare count" instead of "a bare noun phrase".
function isQuantitySetup(u: UnitAnalysis): boolean {
  const words = wordsOf(u);
  if (words.length === 0) return false;
  const first = words[0]!.toLowerCase();
  if (isQuantity(first)) return true;
  return (first === "a" || first === "an") && words.length > 1 && ARTICLE_QUANTIFIABLE.has(words[1]!.toLowerCase());
}

const PREPOSITIONS = new Set([
  "in", "on", "at", "of", "for", "with", "by", "from", "to", "into", "over", "under", "after",
  "before", "during", "through", "about", "against", "between", "across", "behind", "beyond",
]);

const SUBORDINATORS = new Set([
  "because", "since", "although", "though", "while", "when", "whenever", "if", "unless", "whether",
  "that", "which", "who", "whom", "whose", "where", "why", "how",
]);

// Past-tense "-ed" is the other half of the crude verb evidence, and it is what keeps "He counted
// them twice. Sixteen, not fifteen." out — the auxiliary list alone does not see "counted". The
// exception set is the short list of "-ed" words that are adjectives or nouns; a miss here costs
// one finding, never a wrong one. "-ing" is deliberately NOT evidence: "Six weeks of planning" is a
// noun phrase and one of the specimens.
const ED_NOT_VERBS = new Set([
  "red", "bed", "fed", "led", "wed", "bred", "sled", "shed", "speed", "breed", "creed", "deed",
  "greed", "need", "seed", "indeed", "sacred", "hundred", "thousand", "tired", "wicked", "naked",
  "united", "limited", "advanced", "mixed", "used", "aged",
]);

// Irregular past forms, which neither the auxiliary list nor the "-ed" test can see. Kept to forms
// that are rarely anything but a verb: "saw", "left", "lost", "read", "set", "put", "won", "met",
// "fell" and "paid" are all common nouns or adjectives inside a short noun phrase ("the left
// column", "a lost cause") and listing them would suppress real setups. The cost of that omission
// is a missed finding; the cost of including them is a wrong one.
const IRREGULAR_PASTS = new Set([
  "went", "came", "stood", "sat", "took", "made", "ran", "gave", "found", "told", "felt", "knew",
  "thought", "said", "held", "kept", "brought", "bought", "caught", "taught", "sent", "spent",
  "built", "began", "wrote", "spoke", "broke", "chose", "drove", "threw", "grew", "fought",
  "sought", "became", "got", "gotten", "flew", "fled", "shook", "swore", "tore", "wore",
]);

function hasVerbEvidence(w: string): boolean {
  const lower = w.toLowerCase();
  if (FINITE_VERBS.has(lower) || IRREGULAR_PASTS.has(lower)) return true;
  return lower.length > 4 && lower.endsWith("ed") && !ED_NOT_VERBS.has(lower);
}

function isSetupBeat(ctx: Context, u: UnitAnalysis): boolean {
  if (suppressed(ctx, u.span)) return false;
  const words = wordsOf(u);
  if (words.length < 2 || words.length > MAX_SETUP_WORDS) return false;
  if (words.some((w) => hasVerbEvidence(w))) return false;
  const first = words[0]!.toLowerCase();
  if (PREPOSITIONS.has(first) || SUBORDINATORS.has(first)) return false;
  if (VOIDERS.has(first)) return false;
  return true;
}

// --- the turn ---

// Words that take the count away. "not" covers "Not one line shipped"; "no" covers both "No
// decisions" and "no one". Every entry has to VOID rather than merely modify — "few", "some" and
// "half" are absent because "Twelve engineers. Half of them remote." is a report, not a hook.
const VOIDERS = new Set([
  "none", "no", "nobody", "nothing", "never", "neither", "nowhere", "not", "zero",
]);

// Auxiliaries that turn a following "not" into ordinary verb negation rather than a void.
const AUXILIARY_BEFORE_NOT = new Set([
  "do", "does", "did", "will", "would", "can", "could", "shall", "should", "may", "might", "must",
  "is", "are", "was", "were", "am", "be", "been", "has", "have", "had",
]);

// A leading conjunction is part of the formula ("And none you set"), not part of the negation, so
// it is skipped before looking for the voider rather than blocking the match.
const LEADING_CONJUNCTIONS = new Set(["and", "but", "yet", "still", "so"]);

// The void beat: short, and negating within its first couple of tokens. Position matters — a voider
// buried at the end ("Twelve engineers, and the scheduler is not done") is a clause that happens to
// contain a negative, not a beat that opens by taking the count away. Deliberately NOT tested for
// verblessness: the second beat carrying a verb is exactly the case punchy-fragments misses.
const VOIDER_SEARCH_DEPTH = 2;

function isTurnBeat(ctx: Context, u: UnitAnalysis): boolean {
  if (suppressed(ctx, u.span)) return false;
  const words = wordsOf(u);
  if (words.length < 1 || words.length > MAX_TURN_WORDS) return false;

  let i = 0;
  if (LEADING_CONJUNCTIONS.has(words[0]!.toLowerCase())) i = 1;
  for (let j = i; j < Math.min(words.length, i + VOIDER_SEARCH_DEPTH); j++) {
    const w = words[j]!.toLowerCase();
    if (!VOIDERS.has(w)) continue;
    // "not" is the one voider that is also ordinary verb negation. "Do not rely on it." and "The
    // job is not finished." negate a VERB — the setup is still standing, nothing was taken away.
    // Only quantificational "not" voids: "Not one line shipped.", "Not a single test." So when the
    // token is "not", it counts only if nothing auxiliary precedes it.
    if (w === "not" && j > 0 && AUXILIARY_BEFORE_NOT.has(words[j - 1]!.toLowerCase())) continue;
    return true;
  }
  return false;
}

// --- the rule ---

export const setupTurnRule: TropeRule = {
  id: RULE_ID,
  name: "The setup and the turn",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = makeContext(doc);
    const units = doc.units;
    const findings: Finding[] = [];

    for (let i = 0; i + 1 < units.length; i++) {
      const setup = units[i]!;
      const turn = units[i + 1]!;
      if (!isSetupBeat(ctx, setup) || !isTurnBeat(ctx, turn)) continue;

      // Opening position is the formula in its native habitat: a hook is a hook because it is the
      // first thing the reader meets. Mid-document the same pair is likelier to be a writer landing
      // one deliberate beat, so it reports a step lower.
      const opensDocument = i === 0;
      const severity: Severity = opensDocument ? "medium" : "low";

      const setupText = setup.unit.trim();
      const turnText = turn.unit.trim();
      const counted = isQuantitySetup(setup);

      findings.push({
        ruleId: RULE_ID,
        span: spanning([setup, turn]),
        severity,
        message:
          `${counted ? "A bare count" : "A bare noun phrase"} answered by a negation: ` +
          `“${setupText}. ${turnText}.”`,
        explanation:
          `“${setupText}.” is not a sentence. It names a thing and stops, and then “${turnText}.” ` +
          `takes the thing away before the reader has been told anything about it. Two beats in ` +
          `there is still nothing to agree or disagree with, which is the formula working: a frame ` +
          `bought with ${counted ? "a specific-sounding number" : "a noun phrase"} and paid off ` +
          `with a reversal, and no argument made anywhere in it. ` +
          `${opensDocument ? "Opening on it makes it the first thing the reader meets. " : ""}` +
          `Put the setup inside the sentence that makes the argument: what were they, whose were ` +
          `they, and what went wrong because of it.`,
      });

      i++; // a beat belongs to one pair; don't let a void beat also open the next
    }

    return findings;
  },
};
