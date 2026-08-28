// Fragment tier (epic #28, #15) — the fragment-preserving splitter is the whole point: a verbless
// unit ("Not a bug.") is data, not a parse failure (see document.ts and types.ts's UnitOutcome).
// Two rules live here because they share every helper below (short-fragment eligibility, markdown
// suppression, the quote heuristic) and both walk doc.units in document order looking for runs.
//
// Tier: "discourse", not "syntactic". Both rules are fundamentally cross-sentence — punchy-fragments
// measures a document-wide (or run-wide) density and countdown recognizes a shape across 3+ units —
// neither says anything about a single sentence's grammar the way a syntactic rule would.
//
// --- what counts as a fragment here ---
// unit.outcome === "fragment" is the ENTIRE signal: document.ts already decides "verbless" for us
// (no-VP on the tree path, "no-verb:" on the parse-failure path — see document.ts's treeReason and
// readUnit). We do not re-derive verblessness from unit.reason; outcome alone is document.ts's
// considered answer, and unit.reason strings are informal (stub-doc.ts's makeDoc doesn't reproduce
// them at all — see stub-doc.ts). outcome === "unparseable" is a DIFFERENT signal (the parser choked
// on something that does have a predicate, e.g. a "she said" dialogue tag) and is never treated as a
// fragment here, per the issue: "treat parser-fell-over unparseables as NOT fragments."
//
// One consequence, called out in the issue and pinned by document.test.ts ("chunker loses the
// copula"): the rule-based chunker also marks a contracted-copula clause like "It's not bold." as
// "fragment" (it can't see the 's as a verb). We don't special-case that away — instead both rules
// key off the unit's FIRST WORD TOKEN, and "It's" is never "Not"/"No", so the reframe trope ("It's
// not bold — it's backwards.") never satisfies either rule's negation/short-run shape regardless of
// how its outcome got decided.
//
// --- suppression ---
// Two independent filters, applied before a unit is allowed to play ANY role (short fragment,
// negated opener, or countdown cap):
//   markdown   the unit's span sits inside a heading/bullet/codeFence/blockquote line (whole-span
//              containment via markdown.ts's inKind — same idiom rules/formatting.ts uses). A unit
//              from readDocument (document.ts's splitUnits, which does NOT split on newlines) can
//              straddle a heading line and the prose after it when the heading has no terminal
//              punctuation; inKind is strict about whole-span containment, so a straddling unit is
//              NOT suppressed. That's a known gap in the fragment-preserving splitter, not something
//              this rule can fix (document.ts is out of scope for #15) — makeDoc's splitter (which
//              does split on newlines) does not have this problem, which is why the markdown
//              suppression tests below build their fixtures with makeDoc.
//   quotation  dialogue and quoted speech. A "she said" / "he replied" tag on a quoted line usually
//              already saves us for free: hasVerb(unit) sees the verb and document.ts calls the
//              whole unit "unparseable", not "fragment" (see document.ts's readUnit). But bare
//              quoted fragments with no attribution ("Not a bug." "Not a feature.") DO come back
//              verbless. The heuristic: scan the document for quote characters (" " ` and the curly
//              pair), pair them up by simple alternation (odd occurrence opens, even closes) — this
//              is deliberately not a real quote parser, just enough to bound the common case — and
//              suppress a unit whose span overlaps a quoted interval by at least half its own length
//              ("dominated by a quoted span"). A unit fully inside a quoted interval trivially clears
//              that bar, which covers "starts and ends inside quotation marks" too.

import type { DocAnalysis, Finding, Severity, TropeRule, UnitAnalysis, Span, WordSpan } from "../types.js";
import { markdownContext, inKind } from "../markdown.js";
import { spanning } from "../span.js";

// --- word-token helpers ---
// Both makeDoc (stub-doc.ts's wordRe: letters/digits only, contractions kept whole) and the real
// pipeline's tokenizer (offsets.ts's tokenizeWithSpans, which peels a leading quote or a contraction
// apostrophe into its own token) can appear in `words`. Filtering to tokens that CONTAIN a letter or
// digit, and taking the first such token, gives the same answer either way: a stray leading quote
// character is never mistaken for the unit's first word.
const isWordToken = (w: WordSpan): boolean => /[\p{L}\p{N}]/u.test(w.text);

function wordCount(u: UnitAnalysis): number {
  return u.words.filter(isWordToken).length;
}

function firstWord(u: UnitAnalysis): string | undefined {
  return u.words.find(isWordToken)?.text;
}

// Short = at most this many words. Documented threshold, not derived: "Openly" (1), "In a book" (3),
// "As a priest" (3) and "A fundamental design flaw" (4) — the tropes.fyi examples this issue names —
// all fall inside it; a full clause rarely does.
const SHORT_WORD_MAX = 4;

// --- markdown + quote suppression ---

const SUPPRESSED_MARKDOWN_KINDS = ["heading", "bullet", "codeFence", "blockquote"] as const;

function suppressedByMarkdown(ctx: ReturnType<typeof markdownContext>, span: Span): boolean {
  return SUPPRESSED_MARKDOWN_KINDS.some((k) => inKind(ctx, span, k));
}

const QUOTE_CHARS = new Set(['"', "“", "”"]); // " “ ”

// Quote characters in doc.text, paired by simple alternation: 1st opens, 2nd closes, 3rd opens...
// A trailing unmatched opener closes nothing and is dropped. Deliberately naive — see the header
// comment for why a real quote-nesting parser is out of scope here.
function quotedIntervals(text: string): Span[] {
  const positions: number[] = [];
  for (let i = 0; i < text.length; i++) if (QUOTE_CHARS.has(text[i]!)) positions.push(i);
  const intervals: Span[] = [];
  for (let i = 0; i + 1 < positions.length; i += 2) intervals.push({ start: positions[i]!, end: positions[i + 1]! + 1 });
  return intervals;
}

function overlapLength(a: Span, b: Span): number {
  return Math.max(0, Math.min(a.end, b.end) - Math.max(a.start, b.start));
}

// "Dominated by a quoted span": at least half of the unit's own span sits inside some quoted
// interval. A unit fully bookended by quotation marks (the common case) clears this easily.
function suppressedByQuote(intervals: readonly Span[], span: Span): boolean {
  const len = span.end - span.start;
  if (len <= 0) return false;
  for (const q of intervals) {
    if (overlapLength(q, span) * 2 >= len) return true;
  }
  return false;
}

// One pass of suppression state, computed once per detect() call and threaded through both rules.
//
// EXPORTED (not because this file needs it, but because the suppression question is shared): any
// rule that keys off short verbless units has the same two problems these two do — a heading or a
// bullet is not a fragment, and quoted speech is the author quoting someone else. rules/
// quantity-hook.ts reads the same shapes and gets the same answer from here rather than growing a
// second, subtly different copy of the markdown containment test and the quote-pairing heuristic.
// The header above is the documentation for both; keep it that way if a third caller shows up.
export type Context = { markdown: ReturnType<typeof markdownContext>; quotes: readonly Span[] };

export function makeContext(doc: DocAnalysis): Context {
  return { markdown: markdownContext(doc.text), quotes: quotedIntervals(doc.text) };
}

export function suppressed(ctx: Context, span: Span): boolean {
  return suppressedByMarkdown(ctx.markdown, span) || suppressedByQuote(ctx.quotes, span);
}

// ---------------------------------------------------------------------------------------------
// punchy fragments
// ---------------------------------------------------------------------------------------------
// "He published this. Openly. In a book. As a priest." — a lowered opener followed by a run of
// short verbless fragments. Two ways to trip this rule, checked in order per document:
//
//   1. A RUN of >= 2 consecutive eligible short fragments (eligible = outcome "fragment", <= 4
//      words, not suppressed) is direct evidence on its own — "runs...weigh more" from the issue —
//      and fires regardless of how long the rest of the document is. One finding per maximal run,
//      spanning the run; severity "medium" at exactly 2, "high" at 3+.
//   2. Only if NO run fired anywhere in the document: a document-wide density fallback for
//      fragments that never cluster into a run (spread one-per-paragraph, say) but are still
//      frequent enough to be a document-wide tic. Needs >= 2 eligible short fragments total (the
//      absolute floor that keeps one intentional fragment clean) AND a document with >= MIN_UNITS
//      units total (so a two-sentence document can't trip this on density alone) AND density
//      (eligible short fragments / total units) >= 0.3 for "medium", >= 0.5 for "high". One finding
//      spanning the first eligible fragment to the last.
//
// MIN_UNITS only gates the density fallback, not run detection — a run of 2+ short fragments fires
// regardless of how long the surrounding document is (see "He published this..." above, a 4-unit
// document). One consequence: "It's not bold. It's backwards." — both units come back "fragment"
// via the copula-losing bug documented above, both short — DOES form a qualifying run and this rule
// fires on it. That's a legitimate reading under this rule's contract (outcome === "fragment" is
// the signal, full stop; two three-word verbless-per-the-chunker units in a row is exactly what a
// run is), not a bug: the issue's explicit "must not fire on this input" requirement names the
// countdown rule only, because ONLY countdown's shape (negation + cap) is what this specific input
// pretends to be (a reframe, not a countdown). This is documented and tested below rather than
// silently patched around.

const MIN_FRAGMENTS = 2;
const MIN_UNITS = 4;
const DENSITY_MEDIUM = 0.3;
const DENSITY_HIGH = 0.5;

function isShortFragment(ctx: Context, u: UnitAnalysis): boolean {
  return u.outcome === "fragment" && wordCount(u) >= 1 && wordCount(u) <= SHORT_WORD_MAX && !suppressed(ctx, u.span);
}

function punchyRuns(ctx: Context, units: readonly UnitAnalysis[]): UnitAnalysis[][] {
  const runs: UnitAnalysis[][] = [];
  let run: UnitAnalysis[] = [];
  for (const u of units) {
    if (isShortFragment(ctx, u)) {
      run.push(u);
    } else {
      if (run.length >= 2) runs.push(run);
      run = [];
    }
  }
  if (run.length >= 2) runs.push(run);
  return runs;
}

function runFinding(run: UnitAnalysis[]): Finding {
  const severity: Severity = run.length >= 3 ? "high" : "medium";
  return {
    ruleId: "discourse/punchy-fragments",
    span: spanning(run),
    severity,
    message: `${run.length} short fragments in a row`,
    explanation: `${run.length} verbless fragments back to back ("${run[0]!.unit}."...) is the choppy, staccato rhythm AI writing reaches for to manufacture emphasis. One fragment lands; a run of them reads like a drum machine. Let some of these be full sentences.`,
  };
}

export const punchyFragmentsRule: TropeRule = {
  id: "discourse/punchy-fragments",
  name: "Short punchy fragments",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = makeContext(doc);
    const units = doc.units;
    const runs = punchyRuns(ctx, units);
    if (runs.length > 0) return runs.map(runFinding);

    const fragments = units.filter((u) => isShortFragment(ctx, u));
    if (fragments.length < MIN_FRAGMENTS || units.length < MIN_UNITS) return [];
    const density = fragments.length / units.length;
    if (density < DENSITY_MEDIUM) return [];
    const severity: Severity = density >= DENSITY_HIGH ? "high" : "medium";
    const pct = Math.round(density * 100);
    return [
      {
        ruleId: "discourse/punchy-fragments",
        span: spanning(fragments),
        severity,
        message: `${fragments.length} short verbless fragments (${pct}% of sentences)`,
        explanation: `${fragments.length} of this document's ${units.length} sentences are short verbless fragments — not clustered, just a recurring tic throughout. Reserve the fragment for the one moment it earns; write the rest as sentences.`,
      },
    ];
  },
};

// ---------------------------------------------------------------------------------------------
// countdown
// ---------------------------------------------------------------------------------------------
// "Not a bug. Not a feature. A fundamental design flaw." — 2+ consecutive negated fragments capped
// by a unit that does NOT open with Not/No (a fragment or a full clause; "must fire even when the
// capping unit is a full clause" per the issue). Negation is read off the unit's own first word
// token, not a parse — "Not"/"No", case-insensitive, literally. That literal-token requirement is
// what keeps "It's not bold. It's backwards." out: its first word token is "It's" (or "It", split by
// the real tokenizer), never "Not", regardless of the unit's outcome.
//
// A run needs a cap to be a countdown at all — a trailing run with nothing after it (document ends
// mid-count) is not a punchline and does not fire.

const NEGATORS = new Set(["not", "no"]);

function isNegatedFragment(ctx: Context, u: UnitAnalysis): boolean {
  if (u.outcome !== "fragment" || suppressed(ctx, u.span)) return false;
  const w = firstWord(u);
  return w !== undefined && NEGATORS.has(w.toLowerCase());
}

function isCap(ctx: Context, u: UnitAnalysis): boolean {
  if (suppressed(ctx, u.span)) return false;
  const w = firstWord(u);
  return w !== undefined && !NEGATORS.has(w.toLowerCase());
}

export const countdownRule: TropeRule = {
  id: "discourse/countdown",
  name: "The countdown",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = makeContext(doc);
    const units = doc.units;
    const findings: Finding[] = [];
    let run: UnitAnalysis[] = [];

    for (const u of units) {
      if (isNegatedFragment(ctx, u)) {
        run.push(u);
        continue;
      }
      if (run.length >= 2 && isCap(ctx, u)) {
        const severity: Severity = run.length >= 3 ? "high" : "medium";
        findings.push({
          ruleId: "discourse/countdown",
          span: spanning([...run, u]),
          severity,
          message: `countdown — ${run.length} negated fragments, then the reveal`,
          explanation: `"${run.map((r) => r.unit).join(". ")}." builds by ruling things out one at a time before landing on "${u.unit}." — a dramatic countdown to the actual point. Say the point; drop the runway of negations leading up to it.`,
        });
      }
      run = [];
    }
    return findings;
  },
};
