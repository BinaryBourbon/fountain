// THE APHORISTIC ENDER (claude-isms tier, #34) — the compact quotable line a paragraph is parked
// on. Three or four ordinary sentences of argument, then a short verbless or copular tail shaped
// like a fortune cookie:
//
//   "…We rewrote the scheduler twice before the numbers finally moved. A choice, not an accident."
//   "…and the rollout landed a quarter late. Big promises, small results."
//
// It is not the fragment that gives it away (fragments.ts already counts those) and it is not the
// negation (reframe.ts owns denied-then-replaced pairs). What this rule keys on is the POSITION:
// last unit of a paragraph, short, verbless-or-copular, and carrying one of a small set of
// rhetorical shapes — after the paragraph has already spent two or more full-length sentences
// saying the thing. That combination is what turns a sentence into a pull-quote, and doing it at
// the end of paragraph after paragraph is the tell.
//
// --- what has to line up ---
//   position   the LAST unit of a markdown paragraph (markdown.ts's markdownContext paragraphs;
//              a document with no blank lines is one paragraph, which is the right answer).
//   runway     at least MIN_LONGER_UNITS earlier units in the same paragraph, each strictly longer
//              than the ender's own word ceiling. A two-sentence paragraph has no runway to land
//              from, so it never fires.
//   length     at most ENDER_MAX_WORDS word tokens.
//   grammar    verbless (document.ts already decided this: outcome === "fragment") OR copular
//              (ir-query.ts's isCopular on any of the unit's clauses). A short ender with a real
//              transitive verb ("The build passed.") is a plain statement and stays clean — that
//              is the near-miss this rule is measured against.
//   shape      one of the two below. Without a shape the line is just short.
//
// --- the shapes ---
//   comma-inverted contrast / bare "X, not Y" tail
//              a comma followed by "not"/"never": "a stance, not its absence", "the work, never
//              the title". One regex covers both the inverted-contrast form and the bare tail;
//              they are the same punctuation move, and splitting them would only duplicate the
//              explanation.
//   mirrored pair
//              two comma-separated halves of EQUAL word count, 2-4 words each, in a verbless
//              ender: "Big promises, small results." The equal-count requirement is what keeps an
//              ordinary appositive fragment ("Tuesday, the day after the outage") out.
//
// --- what it deliberately does not catch ---
//   * a short ender in dialogue or a pull-quote — a unit dominated by a quoted span is suppressed
//     (the same half-its-own-length test fragments.ts uses), because quoting an aphorism is not
//     writing one.
//   * headings, bullets and code — an ender inside them is a label, not a landing.
//   * the copular ender with no comma at all ("The result was inevitable."). Real, but nothing
//     structural separates it from an ordinary short conclusion, and firing there would bury the
//     shaped hits underneath it.
//
// Severity is per document, not per hit: one aphoristic ender can be earned, two is a habit, three
// or more is the rhythm the reader starts hearing. Per #34 a single instance still reports (low)
// rather than being swallowed by a density floor.

import { isCopular } from "../ir-query.js";
import { inKind, markdownContext } from "../markdown.js";
import type { DocAnalysis, Finding, Severity, Span, TropeRule, UnitAnalysis, WordSpan } from "../types.js";

const RULE_ID = "claude/aphoristic-ender";

const ENDER_MAX_WORDS = 8; // "a stance, not its absence" and friends all sit well inside this
const LONGER_MIN_WORDS = ENDER_MAX_WORDS + 1; // a "longer" unit is one the ender could not be
const MIN_LONGER_UNITS = 2; // the runway the ender lands from

// --- word tokens ---------------------------------------------------------------------------
// Both doc builders can appear in `words` (stub-doc's letters/digits scan, the real pipeline's
// tokenizer that peels quotes into their own token), so count only tokens carrying a letter or
// digit — the same idiom rules/fragments.ts uses.
const isWordToken = (w: WordSpan): boolean => /[\p{L}\p{N}]/u.test(w.text);
const wordCount = (u: UnitAnalysis): number => u.words.filter(isWordToken).length;

// --- suppression ---------------------------------------------------------------------------

const SUPPRESSED_KINDS = ["heading", "bullet", "codeFence", "blockquote"] as const;
const QUOTE_CHARS = new Set(['"', "“", "”"]);

// Quote characters paired by simple alternation (1st opens, 2nd closes). Deliberately not a quote
// parser — enough to recognize "a quoted line", which is all the suppression needs.
function quotedIntervals(text: string): Span[] {
  const at: number[] = [];
  for (let i = 0; i < text.length; i++) if (QUOTE_CHARS.has(text[i]!)) at.push(i);
  const out: Span[] = [];
  for (let i = 0; i + 1 < at.length; i += 2) out.push({ start: at[i]!, end: at[i + 1]! + 1 });
  return out;
}

const overlapLength = (a: Span, b: Span): number => Math.max(0, Math.min(a.end, b.end) - Math.max(a.start, b.start));

// At least half the unit sits inside a quoted interval: dialogue, or an aphorism someone else wrote.
function dominatedByQuote(intervals: readonly Span[], span: Span): boolean {
  const len = span.end - span.start;
  return len > 0 && intervals.some((q) => overlapLength(q, span) * 2 >= len);
}

// --- grammar -------------------------------------------------------------------------------

// Verbless is document.ts's own answer, not something re-derived here: outcome === "fragment"
// means the unit had no predicate to lower (see document.ts's readUnit / treeReason).
const isVerbless = (u: UnitAnalysis): boolean => u.outcome === "fragment";
const isCopularUnit = (u: UnitAnalysis): boolean => (u.clauses ?? []).some(isCopular);

// --- the shapes ----------------------------------------------------------------------------

// "a stance, not its absence" / "the work, never the title" — the comma-inverted contrast and the
// bare "X, not Y" tail, which are the same punctuation move.
const COMMA_CONTRAST = /,\s+(?:not|never)\b/i;

const HALF_MIN_WORDS = 2;
const HALF_MAX_WORDS = 4;
const countWords = (s: string): number => (s.match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu) ?? []).length;

// "Big promises, small results." — one comma, two halves of equal length, no verb anywhere. The
// equal-count test is the whole precision story: an appositive fragment ("Tuesday, the day after
// the outage") has lopsided halves and stays clean.
function isMirroredPair(text: string): boolean {
  const halves = text.split(",");
  if (halves.length !== 2) return false;
  const [a, b] = [countWords(halves[0]!), countWords(halves[1]!)];
  return a === b && a >= HALF_MIN_WORDS && a <= HALF_MAX_WORDS;
}

type Shape = { key: "contrast" | "mirror"; label: string };

function shapeOf(text: string, verbless: boolean): Shape | null {
  if (COMMA_CONTRAST.test(text)) return { key: "contrast", label: "a comma-inverted contrast" };
  if (verbless && isMirroredPair(text)) return { key: "mirror", label: "a mirrored pair" };
  return null;
}

// --- paragraphs ----------------------------------------------------------------------------

// The units wholly inside a paragraph's span, in document order. Whole-span containment, so a unit
// that straddles a paragraph boundary (document.ts's splitUnits does not break on newlines) simply
// belongs to neither — being blunt here is better than attributing an ender to the wrong paragraph.
const unitsIn = (units: readonly UnitAnalysis[], span: Span): UnitAnalysis[] =>
  units.filter((u) => u.span.start >= span.start && u.span.end <= span.end);

const severityFor = (count: number): Severity => (count >= 3 ? "high" : count === 2 ? "medium" : "low");

type Hit = { unit: UnitAnalysis; shape: Shape };

export const aphoristicEnderRule: TropeRule = {
  id: RULE_ID,
  name: "Aphoristic ender (the quotable closing line)",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const quotes = quotedIntervals(doc.text);
    const hits: Hit[] = [];

    for (const paragraph of ctx.paragraphs) {
      const units = unitsIn(doc.units, paragraph.span);
      if (units.length < MIN_LONGER_UNITS + 1) continue;

      const ender = units[units.length - 1]!;
      if (wordCount(ender) < 1 || wordCount(ender) > ENDER_MAX_WORDS) continue;

      const runway = units.slice(0, -1).filter((u) => wordCount(u) >= LONGER_MIN_WORDS).length;
      if (runway < MIN_LONGER_UNITS) continue;

      const verbless = isVerbless(ender);
      if (!verbless && !isCopularUnit(ender)) continue;
      if (dominatedByQuote(quotes, ender.span)) continue;
      if (SUPPRESSED_KINDS.some((k) => inKind(ctx, ender.span, k))) continue;

      const shape = shapeOf(ender.unit, verbless);
      if (shape) hits.push({ unit: ender, shape });
    }

    const severity = severityFor(hits.length);
    const density = hits.length >= 2 ? ` ${hits.length} of this piece's paragraphs land this way; that cadence is the tell.` : "";

    return hits.map(({ unit, shape }) => ({
      ruleId: RULE_ID,
      span: unit.span,
      severity,
      message: `Aphoristic ender: “${unit.unit}” closes the paragraph on ${shape.label}`,
      explanation:
        `You spend the paragraph making the argument, then park it on a short quotable line — ` +
        `“${unit.unit}” — that adds no new information, only cadence. ` +
        (shape.key === "contrast"
          ? `The comma-and-"not" turn makes the last four words sound like a verdict the reader has to accept rather than a claim you argued for. `
          : `The two matched halves sound composed, which is exactly why they read as written-to-be-quoted rather than written-to-be-read. `) +
        `Either fold it back into the sentence before it, or end on the concrete thing you actually established — "The scheduler rewrite cost us two quarters."` +
        density,
    }));
  },
};
