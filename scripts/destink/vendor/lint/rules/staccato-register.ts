// STACCATO REGISTER (#34's other half) — the de-stinked document.
//
// The prompt loop this rule exists for is now a common one: a writer asks a model to strip the
// semicolons, the colons and the em dashes, then asks it again to stop using commas, then again to
// make the sentences shorter, until what comes back is a column of one-sentence paragraphs with
// almost no punctuation inside them. The output reads clean. Nothing was fixed.
//
// The measurement that motivated this rule: the same 400-word argument, once as its author's
// de-punctuated LinkedIn version and once rewritten with ordinary punctuation and paragraphs,
// scores 29.9 and 60.3 respectively under the rest of this registry. Every rule keyed to a
// character the loop deletes — formatting/em-dash-density, tricolon/comma-series — goes quiet, and
// the reframe, the tricolon and the fragment run are all still sitting there in the text. The loop
// is a straight exploit against the scorer, and it does not touch the writing.
//
// --- what the rule actually claims ---
//
// The punctuation did not disappear. It MIGRATED. Every comma that got deleted came back as a full
// stop and every full stop came back as a blank line, so the clause boundaries left the marks and
// moved into the whitespace. That migration is what this rule measures, and it takes both halves to
// see it. Measured over the sample above plus this repo's own prose and two hard negatives:
//
//   document                  internal marks/unit    one-sentence paragraphs
//   the de-punctuated post           0.37                     90%
//   Hemingway, Old Man               0.36                     25%
//   a human LinkedIn post            0.63                     67%
//   README.md                        1.49                     14%
//   DESIGN.md                        1.19                     58%
//   DESTINK.md                       1.42                     15%
//   RESEARCH.md                      1.30                     24%
//
// Neither column is a rule on its own, and the two failures are the whole argument for the
// conjunction. Punctuation starvation alone flags Hemingway HARDER than it flags the post — that is
// issue #35's human-literary false positive arriving by a new road. Paragraph layout alone flags
// the human LinkedIn post and DESIGN.md. Hemingway is sparse but keeps his sentences inside
// paragraphs; the LinkedIn writer breaks her lines but keeps her commas. Doing both is what a
// punctuation ban plus "shorter" plus "shorter" produces, and very little else does.
//
// CAVEAT, stated because the thresholds below look more settled than they are: that table is seven
// documents, five of them from this repo. The gap between 0.63 and 1.19 is clean but it is seven
// points wide. Re-measure over whatever corpus #35 assembles for the Melville false positives
// before treating INTERNAL_PER_UNIT_MAX as anything but a first cut.
//
// --- tier ---
//
// "discourse", for the reason rules/fragments.ts gives for the same choice: this is a document-wide
// density measure over doc.units and says nothing about any one sentence's grammar. It reads
// markdownContext for structure the way the formatting tier does, but a formatting rule does not
// read doc.units and this one is built on them.
//
// --- severity ---
//
// Three tiers, escalating on evidence about the CAUSE, because the base conjunction is a shape
// someone could have chosen on purpose:
//
//   low     the conjunction alone. A register, reported as one.
//   medium  plus punctuation displaced into SYMBOLS. You do not reach for "!=" between two nouns
//           unless "is not" felt forbidden, and you do not shout a whole line in capitals unless
//           the emphasis you wanted had nowhere else to go. This is the tell that the punctuation
//           was avoided rather than simply never needed — which is exactly what separates this
//           document from a plain writer with short sentences.
//   high    plus two or more structural tropes still firing. This is the finding worth reading:
//           the scrub moved the tells, it did not remove them.
//
// SURVIVOR RULES ARE IMPORTED DIRECTLY, NOT VIA registry.ts — same constraint and same resolution
// as rules/sounds-like-claude.ts's header explains: registry.ts imports this file, so importing it
// back to enumerate rules would be a cycle. None of the seven below imports registry.ts.
//
// DETERMINISM: survivor order is declaration order, displacement kinds are reported in a fixed
// order, and every count comes from a pure pass over doc.text — same document in, same finding out.

import type { DocAnalysis, Finding, Severity, TropeRule, UnitAnalysis } from "../types.js";
import { markdownContext, inKind, type MarkdownContext } from "../markdown.js";
import { anaphoraRule } from "./anaphora.js";
import { colonRevealRule } from "./colon-reveal.js";
import { contrastTailRule } from "./contrast-tail.js";
import { punchyFragmentsRule } from "./fragments.js";
import { reframeRule } from "./reframe.js";
import { tricolonRule } from "./tricolon.js";
import { tricolonSeriesRule } from "./tricolon-series.js";

const RULE_ID = "discourse/staccato-register";

// --- gates ---
//
// A reader clocks this register in about five lines, and the rule should too. The floors are
// therefore low: six sentences across four paragraphs is enough to SEE, and the first draft of this
// rule (12 units, 10 paragraphs) stayed silent through the first eleven paragraphs of the post that
// motivated it, which is eleven paragraphs past the point a person would have called it.
//
// What the low floors cost, and how it is paid: the human LinkedIn post in the table above sits at
// 0.63 marks/unit and 67% solo paragraphs, near enough both thresholds that a size gate excluding
// it was really excluding it on a coin-flip. So the size gate does not decide it any more. Below
// SELF_EVIDENT_*, the conjunction alone is not enough — the document must ALSO show corroboration
// (see CORROBORATION below), and that post shows none: no symbols, no glyph markers, nothing
// shouted, and fewer than two structural tropes. It is now excluded on evidence rather than on
// word count, which is the only exclusion that survives someone writing 400 words in that voice.
const MIN_UNITS = 6;
const MIN_PARAGRAPHS = 4;

// Above BOTH of these the density is its own argument and the conjunction fires unaided: at twelve
// sentences across ten paragraphs, "almost no internal punctuation" and "almost every paragraph is
// one sentence" are no longer small-sample artifacts.
const SELF_EVIDENT_UNITS = 12;
const SELF_EVIDENT_PARAGRAPHS = 10;

// Internal punctuation per unit, at or above which the document is punctuated normally. Everything
// in the table that is ordinary prose sits at 1.19 or higher; everything starved sits at 0.63 or
// lower.
const INTERNAL_PER_UNIT_MAX = 0.75;

// Fraction of unit-bearing prose paragraphs that hold exactly one unit, at or above which the
// layout is one-idea-per-line. DESIGN.md's 58% is the highest ordinary-prose reading measured.
const SOLO_PARAGRAPH_MIN = 0.7;

// CORROBORATION. Below the self-evident size, the conjunction has to be joined by independent
// evidence that the punctuation was AVOIDED rather than simply not needed: either the punctuation
// reappearing as symbols (displacementKinds — a symbol where a copula belongs, a glyph list marker,
// a shouted line) or two or more structural tropes still firing. Both are things a plain writer
// with short sentences does not do, and both are things the scrub-the-punctuation loop produces on
// its own. This is what lets the floors above be low without the rule turning into a complaint
// about terse writing.

// Structural tropes that survive a punctuation scrub with their shape intact. Two or more still
// firing is what escalates to "high" — one could be incidental.
const SURVIVORS: readonly TropeRule[] = [
  anaphoraRule,
  colonRevealRule,
  contrastTailRule,
  punchyFragmentsRule,
  reframeRule,
  tricolonRule,
  tricolonSeriesRule,
];
const MIN_SURVIVORS = 2;

// --- counting ---

const WORD_RE = /[\p{L}\p{N}]/u;

// The marks a clause boundary lives in. Em dash and the double-hyphen dash are counted here rather
// than left to formatting/em-dash-density: this rule is measuring whether internal punctuation is
// PRESENT, and a document full of em dashes is not starved even though that rule has its own
// complaint about it. Counting them makes this rule strictly harder to fire, which is the right
// direction for a document-wide claim.
const INTERNAL_RE = /[,;:()]|—|–|--/g;

const hasWord = (u: UnitAnalysis): boolean => WORD_RE.test(u.unit);

function countInternalMarks(ctx: MarkdownContext): number {
  let n = 0;
  for (const m of ctx.text.matchAll(INTERNAL_RE)) {
    const span = { start: m.index!, end: m.index! + m[0].length };
    if (!inKind(ctx, span, "codeFence")) n++;
  }
  return n;
}

// Units are attributed to the paragraph their span STARTS in. A unit that runs past a paragraph
// boundary (splitUnits does not split on newlines — see document.ts) belongs to where it began,
// which is also where a reader would say the sentence is. Paragraphs holding no unit at all — a
// bare label line with no terminal punctuation, say — are not counted in either the numerator or
// the denominator: they are not evidence of one-sentence-per-paragraph OR against it.
type Layout = { solo: number; withUnits: number };

function paragraphLayout(ctx: MarkdownContext, units: readonly UnitAnalysis[]): Layout {
  let solo = 0;
  let withUnits = 0;
  for (const p of ctx.paragraphs) {
    let n = 0;
    for (const u of units) if (u.span.start >= p.span.start && u.span.start < p.span.end) n++;
    if (n === 0) continue;
    withUnits++;
    if (n === 1) solo++;
  }
  return { solo, withUnits };
}

// --- displacement: where the punctuation went ---
//
// Three shapes, each a way of encoding something punctuation used to carry. All three are line
// tests over doc.text, deliberately not parse-based: the point is what the surface looks like.

// A line whose whole content is "<words> <operator> <words>" with no verb in sight — "Capability
// != Authority". The operator is standing in for a copula the writer would otherwise have had to
// spell out. Requires words on both sides so an arithmetic line inside prose is not caught by the
// glyph alone.
const OPERATOR_COPULA_RE = /^\s*[\p{L}\p{N}][^\n]*?\s[≠≈≡≪≫]\s[^\n]*[\p{L}\p{N}][^\n]*$/u;

// A line-initial marker glyph. markdown.ts now classifies these as bullets (see its BULLET_RE
// note), so this test reads the raw line rather than the classification — the question here is not
// "is this a list" but "did the writer reach for a glyph to mark it".
const GLYPH_BULLET_RE = /^ {0,3}[•‣▪▸◦→⇒➜➤]\s+\S/u;

// A whole line shouted. Emphasis with nowhere else to go once the writer has no italics, no bold
// and no punctuation to lean on. Needs >= 3 words and >= 12 characters so an acronym line ("LLM"),
// a heading-ish label ("API") or "OK" never qualifies, and at least one multi-letter word so a line
// of initialisms does not either.
const ALL_CAPS_RE = /^[^\p{Ll}\n]*\p{Lu}[^\p{Ll}\n]*$/u;

function displacementKinds(ctx: MarkdownContext): string[] {
  const kinds: string[] = [];
  let operator = 0;
  let glyph = 0;
  let caps = 0;

  for (const line of ctx.lines) {
    if (line.kind === "codeFence") continue;
    const raw = ctx.text.slice(line.span.start, line.span.end);
    if (OPERATOR_COPULA_RE.test(raw)) operator++;
    if (GLYPH_BULLET_RE.test(raw)) glyph++;
    if (line.kind !== "heading") {
      const words = raw.match(/[\p{L}]{2,}/gu) ?? [];
      if (words.length >= 3 && raw.trim().length >= 12 && ALL_CAPS_RE.test(raw)) caps++;
    }
  }

  // Fixed order, not discovery order — see the header's determinism note.
  if (operator > 0) kinds.push(`${operator} line${operator === 1 ? "" : "s"} using a symbol where a verb belongs`);
  if (glyph > 0) kinds.push(`${glyph} glyph-marked list line${glyph === 1 ? "" : "s"}`);
  if (caps > 0) kinds.push(`${caps} line${caps === 1 ? "" : "s"} shouted in capitals`);
  return kinds;
}

// --- the rule ---

export const staccatoRegisterRule: TropeRule = {
  id: RULE_ID,
  name: "Staccato register (punctuation stripped, tells intact)",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const units = doc.units.filter(hasWord);
    if (units.length < MIN_UNITS) return [];

    const ctx = markdownContext(doc.text);
    const { solo, withUnits } = paragraphLayout(ctx, units);
    if (withUnits < MIN_PARAGRAPHS) return [];

    const internal = countInternalMarks(ctx);
    const perUnit = internal / units.length;
    if (perUnit >= INTERNAL_PER_UNIT_MAX) return [];

    const soloFraction = solo / withUnits;
    if (soloFraction < SOLO_PARAGRAPH_MIN) return [];

    const kinds = displacementKinds(ctx);
    const survivors = SURVIVORS.filter((r) => r.detect(doc).length > 0);

    // See CORROBORATION above: a small document has to show that the punctuation was avoided, not
    // merely absent, before this rule will make a claim about its register.
    const selfEvident = units.length >= SELF_EVIDENT_UNITS && withUnits >= SELF_EVIDENT_PARAGRAPHS;
    if (!selfEvident && kinds.length === 0 && survivors.length < MIN_SURVIVORS) return [];

    const severity: Severity =
      survivors.length >= MIN_SURVIVORS ? "high" : kinds.length > 0 ? "medium" : "low";

    const rounded = Math.round(perUnit * 100) / 100;
    const pct = Math.round(soloFraction * 100);
    const message =
      `${solo} of ${withUnits} paragraphs are a single sentence (${pct}%) and the document averages ` +
      `${rounded} internal punctuation marks per sentence`;

    const parts: string[] = [
      `${solo} of this document's ${withUnits} paragraphs hold exactly one sentence, and across ` +
        `${units.length} sentences there are ${internal} commas, semicolons, colons, parentheses ` +
        `and dashes in total — ${rounded} per sentence, against 1.2 to 1.5 for ordinary prose. ` +
        `The clause boundaries did not go away; they moved out of the punctuation and into the ` +
        `blank lines.`,
    ];

    if (kinds.length > 0) {
      parts.push(
        `The punctuation was avoided rather than never needed: ${kinds.join(", ")}. Nobody puts a ` +
          `symbol between two nouns unless writing "is not" felt off-limits.`,
      );
    }

    if (survivors.length >= MIN_SURVIVORS) {
      parts.push(
        `And the tells are all still here — ${survivors.map((r) => r.id).join(", ")} each still ` +
          `fire on this text. Deleting punctuation relocated them into the line breaks; it did not ` +
          `remove them. Fix the shapes those rules point at, then let the punctuation back in.`,
      );
    } else {
      parts.push(
        `Let some of these sentences join each other. A comma that subordinates one clause to ` +
          `another is doing work no full stop can do, and a reader who is handed one idea per line ` +
          `has to assemble the argument themselves.`,
      );
    }

    return [
      {
        ruleId: RULE_ID,
        span: { start: 0, end: doc.text.length },
        severity,
        message,
        explanation: parts.join(" "),
      },
    ];
  },
};

// Exported for the rule's own tests to assert against without re-deriving the thresholds.
export const THRESHOLDS = {
  MIN_UNITS,
  MIN_PARAGRAPHS,
  SELF_EVIDENT_UNITS,
  SELF_EVIDENT_PARAGRAPHS,
  INTERNAL_PER_UNIT_MAX,
  SOLO_PARAGRAPH_MIN,
  MIN_SURVIVORS,
} as const;
