// COMMA-SERIES TRICOLON (#34) — "A, B, and C" read off the raw text, with no parser involved.
//
// rules/tricolon.ts detects the rule-of-three STRUCTURALLY, out of the Clause IR's `Compound`
// nodes, which is the right way to do it — when the parse produces one. On the no-model path it
// usually doesn't: the rule-based chunker never builds an N-item Compound out of a comma list (it
// merges the conjuncts into one head instead of splitting them), a limit tricolon.ts's own fixture
// file already records as a negative ("She bought apples, bananas, and cherries." — no Compound).
// The consequence is that the single most common real-world tricolon — the comma series in a
// LinkedIn-shaped post — is invisible to the IR rule on the path most users run. This rule closes
// that recall gap by reading the shape off the source text: commas and one coordinator, nothing
// more.
//
// --- the shape ---
//
//   A, B(, C)*, and Z        the Oxford form: the series ends in a segment that OPENS with and/or
//   A, B and Z               the no-Oxford form: the last comma segment carries the coordinator
//                            internally, so the split happens on " and " / " or " inside it
//
// Both need >= 3 items inside ONE unit. Items are runs of words, not single words: "contribute
// code" and "iterate alongside engineering" are items, and requiring single-word items would miss
// every interesting case.
//
// Anything AFTER the coordinated segment is not part of the series and is cut off — that is what
// makes "automate everything you safely can, keep humans in the loop only where risk demands it,
// and bake governance into the design phase, not the end of the pipeline" a 3-item series rather
// than a 4-item one. (The trailing ", not …" there is claude/contrast-tail's finding, not this
// rule's.)
//
// --- precision guards, and what they are actually protecting against ---
//
//   letters      every item must contain a letter and must not be a bare numeral, so the comma in
//                "May 1, 2024" or "1,000, 2,000, and 3,000" cannot manufacture items.
//   length       a non-final item runs to at most ITEM_MAX_WORDS words. #34's brief suggested ~8;
//                the post that motivated the rule has a 10-word item ("keep humans in the loop only
//                where risk demands it"), so 8 would have made the rule blind to its own motivating
//                sample. 12 it is. The FINAL item gets a looser cap (FINAL_ITEM_MAX_WORDS) because
//                the last item of a series routinely absorbs a trailing adjunct belonging to the
//                whole series — "help build the guardrails from day one rather than reviewing after
//                the fact".
//   phrases      a THREE-item series needs at least MIN_MULTIWORD_ITEMS items of more than one
//                word. Three bare nouns ("apples, bananas, and cherries") is an ordinary
//                enumeration, not the rhetorical tic; the tell at that length is the RHYTHM of
//                parallel phrases. This is also what keeps this rule off tricolon.ts's own fixture
//                negative. Four items and up skip the test, for the same reason tricolon.ts flags a
//                4-item Compound on its own: at that length the list is the tell whatever the items
//                are made of.
//
// The span a finding reports runs from the start of the first item to the end of the last, and the
// first item is whatever precedes the first comma — including any sentence opening glued to it
// ("The rollout covered logging, alerting, tracing, …" starts its first item at "The"). Finding
// where a series really begins needs a parser; the span stays honest by covering the whole run.
//
// A comma splice of short clauses ("I came, I saw, I conquered") is deliberately NOT guarded
// against: that is a tricolon, and it should fire.
//
// KNOWN FALSE POSITIVE, accepted: a leading adverbial followed by two coordinated clauses ("Last
// year, the team shipped it, and everyone cheered") has exactly the same comma-and-coordinator
// silhouette as a 3-item series and no parser-free test tells them apart. It fires at "low", the
// gentlest severity there is, which is the honest weight for a shape this ambiguous.
//
// --- not double-firing with the IR rule ---
//
// When the parse DID produce a Compound, tricolon.ts owns the finding. Rather than guess at that
// from here, this rule runs tricolonRule over the same document and drops any of its own findings
// that overlap an IR finding's span. Only the per-compound "tricolon/density" findings count for
// that: the sibling "tricolon/document-density" finding spans the WHOLE document by design, so
// letting it into the overlap test would suppress everything, everywhere, whenever a document
// happened to be tricolon-dense.

import type { DocAnalysis, Finding, Severity, Span, TropeRule, UnitAnalysis } from "../types.js";
import { overlaps } from "../span.js";
import { tricolonRule } from "./tricolon.js";

const RULE_ID = "tricolon/comma-series";

const MIN_ITEMS = 3;
const ITEM_MAX_WORDS = 12; // a non-final item longer than this is a clause, not a list item
const FINAL_ITEM_MAX_WORDS = 16; // the last item carries the series' trailing adjunct
const MIN_MULTIWORD_ITEMS = 2; // a three-item bare-noun enumeration is not the trope
const BARE_LIST_OK_AT = 4; // ...but at four items the list is the tell whatever the items are

const wordRe = (): RegExp => /[\p{L}\p{N}]+(?:['‘’ʼ-][\p{L}\p{N}]+)*/gu;
const wordCount = (s: string): number => (s.match(wordRe()) ?? []).length;
const hasLetter = (s: string): boolean => /\p{L}/u.test(s);

// --- segmentation ---

type Segment = { text: string; span: Span };

// Trim whitespace off both ends of [start, end), keeping the offsets in step.
function trimSpan(text: string, start: number, end: number): Span | null {
  while (start < end && /\s/.test(text[start]!)) start++;
  while (end > start && /\s/.test(text[end - 1]!)) end--;
  return end > start ? { start, end } : null;
}

// The unit minus its trailing punctuation. document.ts's readDocument excludes the terminator from
// a unit's span; stub-doc.ts's makeDoc folds it in. Trimming it here means the last item of a series
// slices to the same text under either document builder.
const TERMINATORS = ".!?;:";
function coreSpan(text: string, span: Span): Span | null {
  let end = span.end;
  while (end > span.start && (/\s/.test(text[end - 1]!) || TERMINATORS.includes(text[end - 1]!))) end--;
  return end > span.start ? { start: span.start, end } : null;
}

// The unit's text cut on every comma, each piece carrying its source offsets. Empty pieces (a
// doubled comma, a trailing one) drop out — they are not items.
function commaSegments(text: string, span: Span): Segment[] {
  const segments: Segment[] = [];
  let start = span.start;
  for (let i = span.start; i <= span.end; i++) {
    if (i < span.end && text[i] !== ",") continue;
    const trimmed = trimSpan(text, start, i);
    if (trimmed) segments.push({ text: text.slice(trimmed.start, trimmed.end), span: trimmed });
    start = i + 1;
  }
  return segments;
}

// "and Z" / "or Z" -> the offset just past the coordinator, or -1 when the segment doesn't open
// with one.
const CONJ_OPENER = /^(?:and|or)\s+/i;
function afterOpeningConj(seg: Segment): number {
  const m = CONJ_OPENER.exec(seg.text);
  return m ? seg.span.start + m[0].length : -1;
}

// The first internal " and " / " or " of a segment: the no-Oxford form's split point, returned as
// [end of the left item, start of the right item].
const INTERNAL_CONJ = /\s+(?:and|or)\s+/i;
function splitInternalConj(seg: Segment): [Span, Span] | null {
  const m = INTERNAL_CONJ.exec(seg.text);
  if (!m) return null;
  const left = trimSpan(seg.text, 0, m.index);
  if (!left) return null;
  const rightStart = m.index + m[0].length;
  const right = trimSpan(seg.text, rightStart, seg.text.length);
  if (!right) return null;
  return [
    { start: seg.span.start + left.start, end: seg.span.start + left.end },
    { start: seg.span.start + right.start, end: seg.span.start + right.end },
  ];
}

// --- the series ---

function itemsOf(text: string, unit: UnitAnalysis): Span[] | null {
  const core = coreSpan(text, unit.span);
  if (!core) return null;
  const segments = commaSegments(text, core);
  if (segments.length < 2) return null;

  // Oxford: the first segment at index >= 2 that opens with a coordinator closes the series, and
  // everything after it (a trailing ", not X" tail, an appended clause) is not part of it.
  const closing = segments.findIndex((s, i) => i >= 2 && afterOpeningConj(s) >= 0);
  if (closing >= 0) {
    const last = segments[closing]!;
    return [...segments.slice(0, closing).map((s) => s.span), { start: afterOpeningConj(last), end: last.span.end }];
  }

  // No Oxford comma: the coordinator lives inside the final segment, which therefore holds the
  // last TWO items. One comma is enough here ("A, B and Z" is three items).
  const tail = segments[segments.length - 1]!;
  if (afterOpeningConj(tail) >= 0) return null; // "A, and B" — two items, not a series
  const split = splitInternalConj(tail);
  if (!split) return null;
  return [...segments.slice(0, -1).map((s) => s.span), ...split];
}

function isSeries(text: string, items: Span[]): boolean {
  if (items.length < MIN_ITEMS) return false;
  const texts = items.map((s) => text.slice(s.start, s.end));
  if (!texts.every(hasLetter)) return false;
  const counts = texts.map(wordCount);
  if (counts.some((n) => n === 0)) return false;
  if (counts.slice(0, -1).some((n) => n > ITEM_MAX_WORDS)) return false;
  if (counts[counts.length - 1]! > FINAL_ITEM_MAX_WORDS) return false;
  if (items.length >= BARE_LIST_OK_AT) return true;
  return counts.filter((n) => n >= 2).length >= MIN_MULTIWORD_ITEMS;
}

// 3 is ordinary rhetoric read once and a tic read twice, so it is visible but gentle; 4-5 is a list
// wearing a sentence; 6+ is an inventory. The escalation mirrors rules/tricolon.ts's own.
const severityFor = (count: number): Severity => (count >= 6 ? "high" : count >= 4 ? "medium" : "low");

// --- the rule ---

type Hit = { span: Span; items: number; first: string; last: string };

function collect(doc: DocAnalysis): Hit[] {
  const hits: Hit[] = [];
  for (const unit of doc.units) {
    const items = itemsOf(doc.text, unit);
    if (!items || !isSeries(doc.text, items)) continue;
    const span: Span = { start: items[0]!.start, end: items[items.length - 1]!.end };
    hits.push({
      span,
      items: items.length,
      first: doc.text.slice(items[0]!.start, items[0]!.end),
      last: doc.text.slice(items[items.length - 1]!.start, items[items.length - 1]!.end),
    });
  }
  return hits;
}

// Spans the IR rule has already claimed. Its document-wide sibling finding is excluded on purpose —
// see the file header.
function irClaimedSpans(doc: DocAnalysis): Span[] {
  return tricolonRule.detect(doc).filter((f) => f.ruleId === "tricolon/density").map((f) => f.span);
}

export const tricolonSeriesRule: TropeRule = {
  id: RULE_ID,
  name: "Tricolon (comma series)",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const hits = collect(doc);
    if (hits.length === 0) return [];
    const claimed = irClaimedSpans(doc);
    return hits
      .filter((h) => !claimed.some((c) => overlaps(c, h.span)))
      .map((h) => ({
        ruleId: RULE_ID,
        span: h.span,
        severity: severityFor(h.items),
        message: `a ${h.items}-item comma series: “${h.first}, … ${h.last}”`,
        explanation:
          `Three parallel phrases in a row land like a drumbeat, and once you hear it you hear it everywhere — ` +
          `“contribute code, iterate alongside engineering, and help build the guardrails”. ` +
          (h.items > 3
            ? `${h.items} items is past rhetoric and into inventory: keep the ones that carry weight and cut the rest. `
            : `Keep the item that does the work and put the others in their own sentence, or drop one and let two do the job. `) +
          `The reader remembers what you said, not how evenly you spaced it.`,
      }));
  },
};
