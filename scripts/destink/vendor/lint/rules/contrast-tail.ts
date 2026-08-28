// CONTRAST TAIL (#34) — the terminal ", not X" dismissal. "Bake governance into the design phase,
// not the end of the pipeline." "Ship the small fix, never the grand rewrite."
//
// This is the em-dash dismissal's quieter cousin and the half of negative parallelism that
// rules/reframe.ts deliberately leaves alone. reframe.ts detects a denial answered by a replacement
// across two CLAUSES ("It is not bold. It is backwards."), and its file header says in as many
// words that the bare "not X, but Y" form is left alone because ordinary English uses it. That
// judgement is right for the mid-sentence form and wrong for the terminal one: a sentence that ends
// by naming the thing it is not is the tic, because the last thing the reader is handed is a
// negation of something nobody proposed.
//
// --- the shape ---
//
// A unit whose LAST comma segment opens with "not" / "never" (optionally "but not" / "but never")
// and reads as a bare phrase rather than a clause. Three tests stand in for "bare phrase", all
// crude and all documented as crude, because this rule reads text and never the IR:
//
//   no verb-ish token   none of the auxiliaries/copulas in AUXILIARIES, and no word ending in
//                       "-ed" or "-ing" anywhere in the tail. "not the end of the pipeline" passes;
//                       "not translated Java" does not (and neither does anything with a real
//                       predicate in it).
//   no subordinator     "because", "since", "although", "while", "when", "if"… A tail carrying one
//                       is a REASON, and "not because X, but because Y" already belongs to
//                       reframe.ts's because-variant (see reframe.ts, BECAUSE-VARIANT). Two rules
//                       reporting the same words teaches the reader nothing twice.
//   length              MIN_TAIL_WORDS..MAX_TAIL_WORDS words. Short denials of a bare noun ("a paper
//                       cut, not a blocker") are ordinary compression and stay clean; the tell is a
//                       trailing phrase substantial enough to mirror the phrase it denies. Past the
//                       upper bound the tail is a clause the verb tests happened to miss.
//
// --- severity, and why it stays gentle ---
//
// Humans write this on purpose, and it is often the right sentence: "She chose the red one, not the
// blue one" IS the pattern and still fires, because the point of the linter is to show you the
// shape, not to tell you it is wrong. So one instance reports at "candidate" (structurally narrowed,
// unconfirmable without semantics — see types.ts), two at "low", three or more at "medium". The
// density is the actual signal: a piece that ends three sentences this way has a tic.
//
// One more reason to stay gentle: fix/fixers/reframe.ts's `reframeContrast` PROPOSAL rewrites a
// reframe into exactly this shape ("The problem was your head, not the code"). A fixed document can
// therefore acquire a contrast-tail candidate that the author never wrote. That proposal is
// human-reviewed and never run by the auto loop (the registered fixer is the pure-deletion
// collapse), so the interaction is a note, not a cycle — see the comment in that file.

import type { DocAnalysis, Finding, Severity, Span, TropeRule } from "../types.js";

const RULE_ID = "claude/contrast-tail";

const MIN_TAIL_WORDS = 4; // "not the blue one" — below this it is ordinary compression
const MAX_TAIL_WORDS = 10; // above this the tail is a clause, whatever the verb tests said
const MIN_HOST_WORDS = 2; // there has to be a sentence in front of the tail for it to dismiss

const TERMINATORS = ".!?;:";

const OPENER = /^(?:but\s+)?(?:not|never)\b/i;

// Crude verb evidence. Deliberately not a POS tagger: this rule runs on the parser-free path, where
// no tags exist, and every entry here is a word that can only be a verb.
const AUXILIARIES = new Set([
  "is", "are", "was", "were", "am", "be", "been", "being",
  "has", "have", "had", "does", "do", "did",
  "will", "would", "can", "could", "shall", "should", "may", "might", "must",
]);

// A tail carrying one of these is a reason, not an appositive — reframe.ts owns those. Kept to the
// words that only ever subordinate a clause: "as", "before", "after" and "until" are prepositions
// at least as often as they are conjunctions ("not until Friday"), and listing them would suppress
// ordinary tails.
const SUBORDINATORS = new Set([
  "because", "since", "although", "though", "while", "when", "whenever", "if", "unless", "whether",
]);

// Nouns and adjectives that end in "-ed"/"-ing" and would otherwise read as verb evidence. Short
// words are excluded by length below ("red", "king", "bed"); these are the longer ones that slip
// through. Not exhaustive, and it does not need to be: a miss here costs one finding, not a wrong
// one.
const NOT_VERBS = new Set([
  "thing", "things", "something", "anything", "everything", "nothing",
  "morning", "evening", "ceiling", "during", "spring", "string", "sibling",
  "indeed", "speed", "breed", "sacred", "hundred", "thousand",
]);

const wordRe = (): RegExp => /[\p{L}\p{N}]+(?:['‘’ʼ-][\p{L}\p{N}]+)*/gu;
const wordsIn = (s: string): string[] => s.match(wordRe()) ?? [];

const looksVerbal = (word: string): boolean => {
  const w = word.toLowerCase();
  if (AUXILIARIES.has(w) || /n['‘’ʼ]t$/.test(w)) return true;
  return /(?:ed|ing)$/.test(w) && w.length > 4 && !NOT_VERBS.has(w);
};

// The unit's text with trailing whitespace and terminating punctuation removed, as a span. Both
// document builders are served by this: document.ts's readDocument excludes the terminator from the
// unit's span already, stub-doc.ts's makeDoc folds it in, and after this they agree.
function coreSpan(text: string, span: Span): Span | null {
  let end = span.end;
  while (end > span.start && (/\s/.test(text[end - 1]!) || TERMINATORS.includes(text[end - 1]!))) end--;
  return end > span.start ? { start: span.start, end } : null;
}

// The trailing ", not …" of one unit, or null. Returns the tail's span in the source.
function contrastTail(text: string, unitSpan: Span): Span | null {
  const core = coreSpan(text, unitSpan);
  if (!core) return null;
  const slice = text.slice(core.start, core.end);

  const comma = slice.lastIndexOf(",");
  if (comma < 0) return null;

  let start = core.start + comma + 1;
  while (start < core.end && /\s/.test(text[start]!)) start++;
  const tail = text.slice(start, core.end);
  if (!OPENER.test(tail)) return null;

  const words = wordsIn(tail);
  if (words.length < MIN_TAIL_WORDS || words.length > MAX_TAIL_WORDS) return null;
  if (words.some((w) => SUBORDINATORS.has(w.toLowerCase()))) return null;
  if (words.some(looksVerbal)) return null;
  if (wordsIn(slice.slice(0, comma)).length < MIN_HOST_WORDS) return null;

  return { start, end: core.end };
}

// One is a sentence a person might mean; three is a habit the reader starts hearing.
const severityFor = (count: number): Severity => (count >= 3 ? "medium" : count === 2 ? "low" : "candidate");

export const contrastTailRule: TropeRule = {
  id: RULE_ID,
  name: "Contrast tail (the trailing “, not X” dismissal)",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const tails = doc.units.flatMap((u) => {
      const span = contrastTail(doc.text, u.span);
      return span ? [span] : [];
    });
    if (tails.length === 0) return [];

    const severity = severityFor(tails.length);
    const density = tails.length >= 2 ? ` You end ${tails.length} sentences this way in this piece; that is the part a reader hears.` : "";
    return tails.map((span) => {
      const tail = doc.text.slice(span.start, span.end);
      return {
        ruleId: RULE_ID,
        span,
        severity,
        message: `the sentence ends on what it isn't: “${tail}”`,
        explanation:
          `Trailing a sentence with “${tail}” hands the reader a denial as the last thing they hold, and usually denies ` +
          `something nobody had proposed. Say the positive version and stop — “bake governance into the design phase” ` +
          `is the whole claim. Keep the contrast only when a reader would genuinely have assumed the other thing.` +
          density,
      };
    });
  },
};
