// Span arithmetic for the linter. Every Finding carries a Span into the ORIGINAL source text, so
// these helpers are what rules use to turn "words 3 through 7 of unit 2" into one highlightable
// range. Nothing here reads the text — offsets only.

import type { Span, DocAnalysis } from "./types.js";

// The source surface form for a span. Rules that need to look at characters (dashes, quotes,
// capitalization) slice through here rather than re-tokenizing.
export const textAt = (source: DocAnalysis | string, span: Span): string =>
  (typeof source === "string" ? source : source.text).slice(span.start, span.end);

// The smallest span covering every part. Takes spans or anything carrying one (WordSpan,
// UnitAnalysis, Finding), so `spanning(unit.words.slice(i, j))` is the common call.
export function spanning(parts: ReadonlyArray<Span | { span: Span }>): Span {
  if (parts.length === 0) throw new Error("spanning: no parts");
  let start = Infinity, end = -Infinity;
  for (const p of parts) {
    const s = "span" in p ? p.span : p;
    if (s.start < start) start = s.start;
    if (s.end > end) end = s.end;
  }
  return { start, end };
}

export const sameSpan = (a: Span, b: Span): boolean => a.start === b.start && a.end === b.end;

// Half-open overlap: [0,3) and [3,5) touch but do not overlap.
export const overlaps = (a: Span, b: Span): boolean => a.start < b.end && b.start < a.end;

export const contains = (outer: Span, inner: Span): boolean =>
  outer.start <= inner.start && inner.end <= outer.end;

// Document order: earlier start wins; on a tie the shorter span comes first, so a nested finding
// is listed before the wider one enclosing it. A ruleId tiebreak makes this a total order.
export const compareSpans = (a: Span, b: Span): number => a.start - b.start || a.end - b.end;
