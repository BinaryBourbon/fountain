// TODO(#9): replace with analyzeDocument when it lands. This function is the seam: score.ts,
// report.ts and the CLI all consume DocAnalysis, never this function directly, so swapping the
// analyzer for #9's real one (which additionally fills in `tree` per unit) is a one-line change at
// each call site — this file, and nothing downstream of it, changes.
//
// Builds a DocAnalysis from readDocument's synchronous, rule-based per-unit split (document.ts) —
// the zero-download path the app already uses when no model is loaded. Word-scanning mirrors
// stub-doc.ts's approach (one regex over each unit's span, offsets carried through from the
// source) rather than importing it: stub-doc.ts is documented test/fixture code, this is product
// code, and the two are allowed to drift independently.

import { readDocument } from "../document.js";
import type { DocAnalysis, DocUnit, Span, UnitAnalysis, WordSpan } from "./types.js";

// A word: letters/digits, with internal apostrophes and hyphens kept ("don't", "well-known",
// "won't" stay whole). Curly and straight apostrophes both count as internal. Mirrors stub-doc.ts's
// wordRe — see that file for the rationale.
const wordRe = (): RegExp => /[\p{L}\p{N}]+(?:['‘’ʼ-][\p{L}\p{N}]+)*/gu;

// Every word inside `span`, in order, with offsets into the whole text.
function wordSpans(text: string, span: Span): WordSpan[] {
  const slice = text.slice(span.start, span.end);
  const words: WordSpan[] = [];
  const re = wordRe();
  for (let m = re.exec(slice); m; m = re.exec(slice)) {
    words.push({ text: m[0], span: { start: span.start + m.index, end: span.start + m.index + m[0].length } });
  }
  return words;
}

const toUnitAnalysis = (text: string, unit: DocUnit): UnitAnalysis => ({ ...unit, words: wordSpans(text, unit.span) });

// The CLI's (and any other non-browser caller's) document analysis: real DocUnits from the
// rule-based chunker/parser, plus word spans scanned per unit. No tree, no POS tags — readDocument
// already says why a unit didn't lower, and nothing here parses further.
export function buildDocAnalysis(text: string): DocAnalysis {
  return { text, units: readDocument(text).map((u) => toUnitAnalysis(text, u)) };
}
