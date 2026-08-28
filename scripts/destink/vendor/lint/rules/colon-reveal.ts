// COLON REVEAL (#34) — the setup-label colon. "Mazal's take:" / "The result:" / "The fix:" and the
// appositive "…an engineering-first security model: one where security teams contribute code…".
//
// The colon is doing what "The result? Devastating." does with a question mark (see
// rules/self-posed-question.ts): it promises a payoff, holds a beat, then delivers. Two or three
// per piece and the whole document reads as a series of announcements.
//
// --- reading the colon at all ---
//
// document.ts's splitUnits treats ":" as a UNIT BOUNDARY, so nothing here ever sees a colon inside a
// unit: the label and the reveal arrive as two consecutive units and the ":" itself sits in the GAP
// between their spans. stub-doc.ts's makeDoc splits the same way but folds the terminator INTO the
// unit, so there the colon is the label unit's last character. Both are legitimate DocAnalysis
// producers, so colonAfter() checks the unit's own trailing punctuation run first and the gap
// second — the same two-convention dance self-posed-question.ts does for "?".
//
// --- two arms ---
//
//   LABEL       a unit of at most LABEL_MAX_WORDS words, ending in ":", followed by a unit of at
//               least REVEAL_MIN_WORDS words. "Mazal's take: automate everything you safely can…"
//               The label is not a sentence; it is a nameplate on one.
//   APPOSITIVE  any unit ending in ":" whose next unit OPENS with one of REVEAL_OPENERS — "one
//               where…", "a place where…", "the kind that…". Mid-sentence, the colon here restates
//               the noun it just introduced, at length, as a reveal. Held to a fixed opener list on
//               purpose: without one, every explanatory colon in technical prose would fire.
//
// --- suppressions ---
//
//   markdown    a label sitting on a heading or bullet line is document structure, not rhetoric
//               ("## Results:", "- Timeout: 30s"). Code fences too.
//   convention  "Note:", "Warning:", "Example:", "TL;DR:", "Source:", "Update:" and friends are
//               conventional labels with no reveal in them. Matched against the WHOLE label, so
//               "The note he left:" is not exempted by "note". ("TL;DR" arrives as two units, "TL"
//               and "DR", because ";" is also a unit boundary — hence both halves in the list.)
//   timestamps  "3:30" — the label ends in a digit and the reveal starts with one.
//   URLs        "https://example.com" and "mailto:someone" — the label's last word is a scheme, or
//               the colon is immediately followed by "//".
//
// Severity: low for a single reveal, medium once the document does it twice or more. The label form
// is visible on its own hit (#34), which is why one is "low" and not "candidate".

import type { DocAnalysis, Finding, Severity, Span, TropeRule, UnitAnalysis } from "../types.js";
import { markdownContext, kindAt } from "../markdown.js";
import type { MarkdownContext } from "../markdown.js";
import { spanning } from "../span.js";

const RULE_ID = "claude/colon-reveal";

const LABEL_MAX_WORDS = 4; // "Mazal's take" / "The result" / "His argument" / "The fix"
const REVEAL_MIN_WORDS = 3; // a one-word payoff after a label is a caption, not a reveal beat

const TERMINATORS = ".!?;:";

// Openers that make a colon an appositive reveal rather than an ordinary explanatory colon.
const REVEAL_OPENERS = [
  "one where", "one that", "one in which",
  "a place where", "a world where", "a kind of",
  "the kind that", "the sort that", "the one that",
];

// Conventional labels — structure, not rhetoric. Compared against the whole label, letters only.
const CONVENTIONAL_LABELS = new Set([
  "note", "notes", "warning", "warnings", "caution", "important", "example", "examples",
  "tip", "tips", "tl", "dr", "tldr", "source", "sources", "reference", "references",
  "update", "updates", "edit", "disclaimer", "todo", "fixme", "input", "output", "usage",
  "see also", "context", "status", "author", "date", "version",
]);

const URL_SCHEMES = new Set(["http", "https", "ftp", "ftps", "mailto", "file", "data", "tel"]);

// --- terminator-gap helpers (see the file header) ---

const gapAfter = (doc: DocAnalysis, i: number): Span => ({
  start: doc.units[i]!.span.end,
  end: i + 1 < doc.units.length ? doc.units[i + 1]!.span.start : doc.text.length,
});

// The run of terminator punctuation at the very end of a unit's own span, e.g. "The result:" -> ":".
function trailingTerminators(text: string, span: Span): string {
  let end = span.end;
  while (end > span.start && /\s/.test(text[end - 1]!)) end--;
  let start = end;
  while (start > span.start && TERMINATORS.includes(text[start - 1]!)) start--;
  return text.slice(start, end);
}

// The offset of the ":" that ends unit `i`, or -1. Checks the unit's own trailing run first (makeDoc)
// and then the gap to the next unit (readDocument).
function colonAfter(doc: DocAnalysis, i: number): number {
  const u = doc.units[i]!;
  const own = trailingTerminators(doc.text, u.span);
  if (own.includes(":")) return doc.text.lastIndexOf(":", u.span.end - 1);
  const gap = gapAfter(doc, i);
  const at = doc.text.indexOf(":", gap.start);
  return at >= 0 && at < gap.end ? at : -1;
}

// --- guards ---

const labelKey = (u: UnitAnalysis): string => u.words.map((w) => w.text.toLowerCase()).join(" ");

function isUrlColon(doc: DocAnalysis, label: UnitAnalysis, colon: number): boolean {
  if (doc.text.startsWith("//", colon + 1)) return true;
  const last = label.words[label.words.length - 1];
  return !!last && URL_SCHEMES.has(last.text.toLowerCase());
}

// "at 3:30" — a digit on each side of the colon, with no space between. Both sides are required:
// "The count: 42 machines went down" has a digit only after it and is a real label.
const isTimestamp = (doc: DocAnalysis, colon: number): boolean =>
  /\d/.test(doc.text[colon - 1] ?? "") && /\d/.test(doc.text[colon + 1] ?? "");

function inMarkdownStructure(ctx: MarkdownContext, span: Span): boolean {
  const kind = kindAt(ctx, span.start);
  return kind === "heading" || kind === "bullet" || kind === "codeFence";
}

const revealOpener = (doc: DocAnalysis, reveal: UnitAnalysis): string | null => {
  const opening = doc.text.slice(reveal.span.start, reveal.span.end).toLowerCase();
  return REVEAL_OPENERS.find((o) => opening.startsWith(o)) ?? null;
};

// --- collect ---

type Arm = "label" | "appositive";
type Hit = { arm: Arm; span: Span; label: string; reveal: string };

function collect(doc: DocAnalysis, ctx: MarkdownContext): Hit[] {
  const hits: Hit[] = [];
  for (let i = 0; i + 1 < doc.units.length; i++) {
    const label = doc.units[i]!;
    const reveal = doc.units[i + 1]!;
    if (label.words.length === 0 || reveal.words.length === 0) continue;

    const colon = colonAfter(doc, i);
    if (colon < 0) continue;
    if (isUrlColon(doc, label, colon)) continue;
    if (isTimestamp(doc, colon)) continue;
    if (CONVENTIONAL_LABELS.has(labelKey(label))) continue;
    if (inMarkdownStructure(ctx, label.span) || inMarkdownStructure(ctx, reveal.span)) continue;

    // LABEL arm: the whole short label is the setup, so the finding spans it, word to word — the
    // colon itself is inside neither unit span under readDocument, and inside the label's under
    // makeDoc, so spanning the WORDS is the one construction both builders agree on.
    if (label.words.length <= LABEL_MAX_WORDS && reveal.words.length >= REVEAL_MIN_WORDS) {
      hits.push({
        arm: "label",
        span: spanning(label.words),
        label: doc.text.slice(label.span.start, label.span.end).replace(/[:\s]+$/, ""),
        reveal: doc.text.slice(reveal.span.start, reveal.span.end),
      });
      continue;
    }

    // APPOSITIVE arm: the setup is a whole sentence, so the finding narrows to the junction — the
    // noun being restated, the colon, and the opener that restates it.
    const opener = revealOpener(doc, reveal);
    if (!opener) continue;
    const noun = label.words[label.words.length - 1]!;
    const openerEnd = reveal.span.start + opener.length;
    hits.push({
      arm: "appositive",
      span: { start: noun.span.start, end: openerEnd },
      label: noun.text,
      reveal: doc.text.slice(reveal.span.start, reveal.span.end),
    });
  }
  return hits;
}

const severityFor = (count: number): Severity => (count >= 2 ? "medium" : "low");

export const colonRevealRule: TropeRule = {
  id: RULE_ID,
  name: "Colon reveal (the setup label)",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const hits = collect(doc, ctx);
    if (hits.length === 0) return [];

    const severity = severityFor(hits.length);
    const density = hits.length >= 2 ? ` You set up ${hits.length} sentences this way in this piece.` : "";
    return hits.map((h) => {
      const opening = (n: number): string => h.reveal.split(/\s+/).slice(0, n).join(" ");
      return {
        ruleId: RULE_ID,
        span: h.span,
        severity,
        message:
          h.arm === "label"
            ? `“${h.label}:” — a nameplate, then the sentence`
            : `“${h.label}: ${opening(2)}…” — the noun restated as a reveal`,
        explanation:
          (h.arm === "label"
            ? `“${h.label}:” announces that a point is coming instead of making it. The colon buys a beat of suspense ` +
              `for a sentence that would land harder on its own — start with “${opening(4)}…” and let the claim carry itself.`
            : `The colon here restates the noun you just introduced — “${h.label}” — and then spends a clause explaining it. ` +
              `That is a definition wearing a dramatic pause. Fold it into the sentence (“a security model where teams contribute code”) ` +
              `or make it its own sentence and drop the colon.`) + density,
      };
    });
  },
};
