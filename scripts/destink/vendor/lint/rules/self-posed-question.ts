// Self-posed question (epic #28, #16) — "The result? Devastating." / "The worst part? Nobody saw
// it coming." A unit that ends in "?" immediately followed by a short declarative (or fragment)
// answer: the writer asks their own question so they can deliver the "reveal" themselves.
//
// Terminator gap. document.ts's readDocument (the real, parsed path) EXCLUDES a unit's terminating
// punctuation from its span: "The result? Devastating." splits into two units, "The result" and
// "Devastating", with the "?" sitting in neither span — it's in the gap between them. stub-doc.ts's
// makeDoc does the opposite and folds the terminator INTO the unit's own trailing text. Both are
// legitimate DocAnalysis producers, so unitEndsWith() below checks both: the unit's own trailing
// terminator run first, then the gap up to the next unit (or end of document).
//
// Two forms, by how the question is shaped:
//
//   STRONG  "The X?" — at most STRONG_MAX_WORDS words AND the outcome is "fragment"/"unparseable"
//           (no verb came out of it; a bare NP dressed as a question). This is the shape from the
//           tropes list, and the strongest signal: nobody drops a subject and asks a two-word
//           question except for the reveal-beat effect. Fires with any answer up to
//           MAX_ANSWER_WORDS words.
//
//   WEAK    Anything else that still ends in "?" — a real interrogative clause (has a verb; would
//           parse as SQ/SBARQ if a constituency parser ever labels questions that way — the
//           rule-based chunker in nlp/parse.ts normalizes questions to declarative order before
//           parsing and never produces that label, so this is a forward-looking check, not a live
//           one against the current parser) or simply a longer fragment ending in "?". A real
//           question deserves a real answer, so this only fires when the answer is a short punchy
//           fragment (<= WEAK_ANSWER_MAX_WORDS words) — "Why does this matter? Because it always
//           does." reads as the same beat as the strong form. A real question answered at length
//           (FAQ prose, a tutorial) is exactly what this rule must stay quiet on.
//
// Either form is suppressed across a markdown heading boundary: the question itself is a heading
// line, or a heading sits between the question and its answer. "## The result?\n\nDevastating." is
// a section title and its body, not a self-posed question.
//
// Density (whole document, both forms pooled): 1 instance -> low if it's the strong form, nothing
// at all if it's the lone weak-form hit (a single real question briefly answered is not yet a
// pattern); 2 instances -> medium; 3+ -> high.

import type { DocAnalysis, Finding, Severity, TropeRule, UnitAnalysis } from "../types.js";
import type { MarkdownContext } from "../markdown.js";
import { markdownContext, kindAt } from "../markdown.js";
import { spanning } from "../span.js";

const STRONG_MAX_WORDS = 4; // "The result?" / "The worst part?" / "The scary part?"
const MAX_ANSWER_WORDS = 12; // beyond this the question was answered at length — never fires
const WEAK_ANSWER_MAX_WORDS = 6; // the weak form only fires when the answer is this punchy

const TERMINATOR_CHARS = ".!?;:";

// --- terminator-gap helpers ---

// The text between this unit's own span and the next unit's span (or the end of the document for
// the last unit) — the region where a splitter that excludes terminators leaves them.
function gapAfter(doc: DocAnalysis, i: number): string {
  const start = doc.units[i]!.span.end;
  const end = i + 1 < doc.units.length ? doc.units[i + 1]!.span.start : doc.text.length;
  return doc.text.slice(start, end);
}

// The run of terminator punctuation at the very end of `text` (after trimming trailing whitespace),
// e.g. "Wait?!" -> "?!", "Not a bug." -> ".", "Devastating" -> "".
function trailingTerminators(text: string): string {
  const trimmed = text.replace(/\s+$/, "");
  let end = trimmed.length;
  while (end > 0 && TERMINATOR_CHARS.includes(trimmed[end - 1]!)) end--;
  return trimmed.slice(end);
}

// True when unit `i` ends with `ch`, whichever splitter convention produced `doc`: check the unit's
// own trailing terminator run first (makeDoc folds the terminator into the unit), then the gap after
// it (readDocument excludes the terminator from the unit and leaves it in the gap).
function unitEndsWith(doc: DocAnalysis, i: number, ch: string): boolean {
  const u = doc.units[i]!;
  if (trailingTerminators(doc.text.slice(u.span.start, u.span.end)).includes(ch)) return true;
  return gapAfter(doc, i).includes(ch);
}

// True only for the document's last unit, and only when nothing — not even a terminator — follows
// it: the text just stops ("...and the winner is Devastating" with no closing punctuation at all).
function endsDocumentUnterminated(doc: DocAnalysis, i: number): boolean {
  if (i !== doc.units.length - 1) return false;
  return !/[.!?;:]/.test(gapAfter(doc, i));
}

const isQuestionUnit = (doc: DocAnalysis, i: number): boolean => unitEndsWith(doc, i, "?");

const isDeclarativeAnswer = (doc: DocAnalysis, i: number): boolean =>
  unitEndsWith(doc, i, ".") || unitEndsWith(doc, i, "!") || endsDocumentUnterminated(doc, i);

// --- shape ---

// No clause came out of this unit — fragment or unparseable outcome both mean "no verb found",
// which for a 1-4 word unit ending in "?" is the "The result?" shape, not a truncated real question.
const looksVerbless = (u: UnitAnalysis): boolean => u.outcome !== "lowered";

const isStrongQuestion = (doc: DocAnalysis, i: number): boolean =>
  doc.units[i]!.words.length <= STRONG_MAX_WORDS && looksVerbless(doc.units[i]!);

// --- markdown suppression ---

// document.ts's readDocument only splits on . ! ? ; : — never on a bare newline — so a heading
// interposed between a question and its answer with no other boundary punctuation ends up glued to
// the FRONT of the answer unit's own span rather than sitting in the gap before it ("The result?\n##
// Aside\nDevastating." has its answer unit start at "## Aside"). Using aSpan.end rather than
// aSpan.start as the upper bound catches that merged case too, alongside the clean
// question-gap-heading-answer shape a newline-splitting doc builder (makeDoc) produces.
function crossesHeadingBoundary(
  ctx: MarkdownContext,
  qSpan: { start: number; end: number },
  aSpan: { start: number; end: number },
): boolean {
  if (kindAt(ctx, qSpan.start) === "heading") return true; // the question IS a heading
  return ctx.lines.some((l) => l.kind === "heading" && l.span.start >= qSpan.end && l.span.start < aSpan.end);
}

// --- collect ---

type Instance = { kind: "strong" | "weak"; qIndex: number; aIndex: number };

function collectInstances(doc: DocAnalysis, ctx: MarkdownContext): Instance[] {
  const out: Instance[] = [];
  for (let i = 0; i < doc.units.length - 1; i++) {
    if (!isQuestionUnit(doc, i)) continue;
    const j = i + 1;
    if (!isDeclarativeAnswer(doc, j)) continue;

    const answerWords = doc.units[j]!.words.length;
    if (answerWords > MAX_ANSWER_WORDS) continue; // answered at length — a real FAQ, not the trope

    const strong = isStrongQuestion(doc, i);
    if (!strong && answerWords > WEAK_ANSWER_MAX_WORDS) continue; // a real question, answered properly

    if (crossesHeadingBoundary(ctx, doc.units[i]!.span, doc.units[j]!.span)) continue;

    out.push({ kind: strong ? "strong" : "weak", qIndex: i, aIndex: j });
  }
  return out;
}

function buildFinding(doc: DocAnalysis, inst: Instance, severity: Severity, total: number): Finding {
  const q = doc.units[inst.qIndex]!;
  const a = doc.units[inst.aIndex]!;
  const qText = doc.text.slice(q.span.start, q.span.end);
  const aText = doc.text.slice(a.span.start, a.span.end);
  const countNote = total > 1 ? ` — ${total} in this piece` : "";

  const message =
    inst.kind === "strong"
      ? `"${qText}?" answered in the next breath${countNote}`
      : `"${qText}?" — a real question, answered in one short beat${countNote}`;

  const explanation =
    inst.kind === "strong"
      ? `You ask "${qText}?" and immediately answer it yourself: "${aText}." That's a manufactured reveal for something you could just state — "${qText} was ${aText.toLowerCase()}." Say the thing, no question required.`
      : `"${qText}?" reads like a real question, but you answer it in a single short beat: "${aText}." Either commit to the question and answer it properly, or drop the question mark and lead with "${aText}" directly.`;

  return {
    ruleId: "syntactic/self-posed-question",
    span: spanning([q.span, a.span]),
    severity,
    message,
    explanation,
  };
}

export const selfPosedQuestionRule: TropeRule = {
  id: "syntactic/self-posed-question",
  name: "Self-posed question",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const instances = collectInstances(doc, ctx);
    if (instances.length === 0) return [];

    if (instances.length === 1) {
      const only = instances[0]!;
      if (only.kind === "weak") return []; // one real, briefly-answered question isn't a pattern yet
      return [buildFinding(doc, only, "low", 1)];
    }

    const severity: Severity = instances.length >= 3 ? "high" : "medium";
    return instances.map((inst) => buildFinding(doc, inst, severity, instances.length));
  },
};
