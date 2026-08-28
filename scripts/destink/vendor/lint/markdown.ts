// Markdown-aware pre-scan (epic #28, #21). Parser-free: no remark/markdown-it dependency, just
// line-based classification. This is the shared structural context that the formatting tier reads
// directly and that #15/#16's rules will call into for suppression ("don't fire inside a code
// fence", "this negative-parallelism hit is in a heading, downweight it"). Keep the API small and
// stable — two other agents build against it after this lands.
//
// markdownContext(text) is pure: same input, same output, no I/O. It never re-slices doc.text for
// rules — every Span it hands back slices cleanly from the ORIGINAL text passed in.
//
// What counts as what (documented because none of this is a real markdown parser):
//   heading     ATX only: /^ {0,3}#{1,6}(\s|$)/. Setext headings (underlined with ===/---) are not
//               detected — a === or --- line reads as prose. Rare enough in prose docs to skip.
//   bullet      A line starting (after up to 3 leading spaces) with one of the ASCII markers
//               (-, *, +), one of the GLYPH markers (see BULLET_RE), or a decimal number followed
//               by . or ) — in every case followed by whitespace ("- ", "\u2022 ", "1. ", "2) ").
//   codeFence   A line starting (after up to 3 leading spaces) with 3+ backticks or 3+ tildes opens
//               a fence; every line up to and including the matching close (same character, count
//               >= the opener's) is "codeFence", closer included. An unterminated fence runs to the
//               end of the document — better to over-suppress than to lint inside broken fences.
//               Fences do not nest and are not recognized inside another fence.
//   blockquote  A line starting (after up to 3 leading spaces) with '>'.
//   prose       Everything else that isn't blank.
//   (blank)     Whitespace-only lines are not classified at all — they don't appear in `lines`, they
//               only act as separators when grouping paragraphs and lists.
//
// Precedence when a line could match more than one thing: fence state wins first (checked before
// anything else, and while a fence is open every line is "codeFence" regardless of shape), then
// heading, then blockquote, then bullet, then prose. So "> # not a heading" is a blockquote line,
// not a heading — only the leading marker is used to classify.

import type { Span } from "./types.js";

export type MarkdownKind = "heading" | "bullet" | "codeFence" | "blockquote" | "prose";

type BaseLine = { span: Span; lineIndex: number };

export type HeadingLine = BaseLine & { kind: "heading"; level: number };
export type BulletLine = BaseLine & {
  kind: "bullet";
  ordered: boolean;
  markerSpan: Span; // the marker itself: "-", "*", "+", or "3."/"3)"
  contentSpan: Span; // the item's text after the marker and its following whitespace
};
export type CodeFenceLine = BaseLine & { kind: "codeFence"; fenceChar: "`" | "~"; isDelimiter: boolean };
export type BlockquoteLine = BaseLine & { kind: "blockquote" };
export type ProseLine = BaseLine & { kind: "prose" };

export type MarkdownLine = HeadingLine | BulletLine | CodeFenceLine | BlockquoteLine | ProseLine;

// A run of consecutive bullet lines with nothing (not even a blank line) between them. Loose lists
// (blank line between items) are deliberately NOT merged into one block — that's a simplification
// documented here, not an oversight: it means two "tight" runs separated by a blank line count as
// two lists for fraction purposes. Revisit if a real fixture needs otherwise.
export type ListItem = { span: Span; contentSpan: Span; ordered: boolean };
export type ListBlock = { span: Span; items: ListItem[] };

// A run of consecutive prose lines with nothing between them (blank lines, or a heading/bullet/
// blockquote/code line, end the paragraph).
export type Paragraph = { span: Span; lines: Span[] };

export type MarkdownContext = {
  text: string;
  lines: MarkdownLine[]; // non-blank lines only, in document order
  codeFences: Span[]; // whole fenced blocks, opening fence line through closing fence line
  lists: ListBlock[];
  paragraphs: Paragraph[];
};

// Split into raw line spans. Handles a trailing CRLF by excluding the \r from the span so slices
// never carry it; a final line with no trailing newline is still included.
function splitLines(text: string): Span[] {
  const spans: Span[] = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "\n") continue;
    const end = i > start && text[i - 1] === "\r" ? i - 1 : i;
    spans.push({ start, end });
    start = i + 1;
  }
  spans.push({ start, end: text.length });
  return spans;
}

const FENCE_RE = /^ {0,3}(`{3,}|~{3,})/;
const HEADING_RE = /^ {0,3}(#{1,6})(\s|$)/;
const BLOCKQUOTE_RE = /^ {0,3}>/;
// Bullet markers. The ASCII set (-, *, +) is CommonMark's. The glyph set is not: CommonMark reads
// a line opening with \u2022 or \u2192 as an ordinary paragraph. That is the right call for a
// renderer and the wrong one for a linter that reasons about document SHAPE — a writer pasting a
// list out of a word processor, or a chat model asked for a list and reaching for a decorative
// marker, produces a list either way. Classifying those lines as prose silently blinded
// bold-first-bullet, listicle-in-trench-coat, and the paragraph grouping every discourse rule reads
// (rules/staccato-register.ts counts one-sentence paragraphs; eight arrow-marked lines used to
// group into one 8-line "paragraph").
//
// The glyph set is deliberately narrow — a marker has to be unambiguous at the START of a line with
// whitespace after it. Included: \u2022 \u2023 \u25AA \u25B8 \u25E6 \u00B7 (bullet glyphs proper)
// and \u2192 \u21D2 \u279C \u27A4 (arrows used as markers, the shape a de-punctuated document
// reaches for). NOT included: emoji and dingbats (formatting/unicode-decoration reports those as
// decoration, and a leading emoji is as often ornament as it is a marker), and the astral ranges
// generally, so every marker here is one UTF-16 code unit and markerSpan arithmetic stays honest.
const BULLET_RE = /^( {0,3})([-*+\u2022\u2023\u25AA\u25B8\u25E6\u00B7\u2192\u21D2\u279C\u27A4])(\s+)(?=\S|$)/;
const ORDERED_BULLET_RE = /^( {0,3})(\d{1,9}[.)])(\s+)(?=\S|$)/;

export function markdownContext(text: string): MarkdownContext {
  const rawLines = splitLines(text);
  const lines: MarkdownLine[] = [];
  const codeFences: Span[] = [];

  let fence: { char: "`" | "~"; len: number; openIndex: number } | null = null;

  for (let i = 0; i < rawLines.length; i++) {
    const span = rawLines[i]!;
    const raw = text.slice(span.start, span.end);

    if (fence) {
      const closeMatch = raw.match(FENCE_RE);
      const isClose =
        !!closeMatch &&
        closeMatch[1]![0] === fence.char &&
        closeMatch[1]!.length >= fence.len &&
        raw.trim() === closeMatch[1];
      lines.push({ kind: "codeFence", span, lineIndex: i, fenceChar: fence.char, isDelimiter: isClose });
      if (isClose) {
        codeFences.push({ start: rawLines[fence.openIndex]!.start, end: span.end });
        fence = null;
      }
      continue;
    }

    if (raw.trim() === "") continue; // blank — not classified, just a separator

    const openMatch = raw.match(FENCE_RE);
    if (openMatch) {
      const marker = openMatch[1]!;
      fence = { char: marker[0] as "`" | "~", len: marker.length, openIndex: i };
      lines.push({ kind: "codeFence", span, lineIndex: i, fenceChar: fence.char, isDelimiter: true });
      continue;
    }

    const heading = raw.match(HEADING_RE);
    if (heading) {
      lines.push({ kind: "heading", span, lineIndex: i, level: heading[1]!.length });
      continue;
    }

    if (BLOCKQUOTE_RE.test(raw)) {
      lines.push({ kind: "blockquote", span, lineIndex: i });
      continue;
    }

    const bullet = raw.match(BULLET_RE);
    const orderedBullet = raw.match(ORDERED_BULLET_RE);
    const m = bullet ?? orderedBullet;
    if (m) {
      const markerStart = span.start + m[1]!.length;
      const markerEnd = markerStart + m[2]!.length;
      const contentStart = markerEnd + m[3]!.length;
      lines.push({
        kind: "bullet",
        span,
        lineIndex: i,
        ordered: !bullet,
        markerSpan: { start: markerStart, end: markerEnd },
        contentSpan: { start: contentStart, end: span.end },
      });
      continue;
    }

    lines.push({ kind: "prose", span, lineIndex: i });
  }

  // An unterminated fence runs to the end of the document.
  if (fence) codeFences.push({ start: rawLines[fence.openIndex]!.start, end: rawLines[rawLines.length - 1]!.end });

  return { text, lines, codeFences, lists: groupLists(lines), paragraphs: groupParagraphs(lines) };
}

function groupLists(lines: readonly MarkdownLine[]): ListBlock[] {
  const lists: ListBlock[] = [];
  let current: ListItem[] = [];
  let lastLineIndex = -2;

  const flush = () => {
    if (current.length > 0) lists.push({ span: { start: current[0]!.span.start, end: current[current.length - 1]!.span.end }, items: current });
    current = [];
  };

  for (const line of lines) {
    if (line.kind === "bullet" && line.lineIndex === lastLineIndex + 1) {
      current.push({ span: line.span, contentSpan: line.contentSpan, ordered: line.ordered });
      lastLineIndex = line.lineIndex;
      continue;
    }
    flush();
    if (line.kind === "bullet") {
      current.push({ span: line.span, contentSpan: line.contentSpan, ordered: line.ordered });
      lastLineIndex = line.lineIndex;
    } else {
      lastLineIndex = -2;
    }
  }
  flush();
  return lists;
}

function groupParagraphs(lines: readonly MarkdownLine[]): Paragraph[] {
  const paragraphs: Paragraph[] = [];
  let current: Span[] = [];
  let lastLineIndex = -2;

  const flush = () => {
    if (current.length > 0) paragraphs.push({ span: { start: current[0]!.start, end: current[current.length - 1]!.end }, lines: current });
    current = [];
  };

  for (const line of lines) {
    if (line.kind === "prose" && line.lineIndex === lastLineIndex + 1) {
      current.push(line.span);
      lastLineIndex = line.lineIndex;
      continue;
    }
    flush();
    if (line.kind === "prose") {
      current.push(line.span);
      lastLineIndex = line.lineIndex;
    } else {
      lastLineIndex = -2;
    }
  }
  flush();
  return paragraphs;
}

// The classification of the line containing `offset`, or undefined for a blank line (or an offset
// past the end of the document). Uses the line whose span contains offset, with the last line's end
// treated as inclusive so an offset exactly at end-of-text still resolves.
export function kindAt(ctx: MarkdownContext, offset: number): MarkdownKind | undefined {
  for (const line of ctx.lines) {
    if (offset >= line.span.start && offset <= line.span.end) return line.kind;
  }
  return undefined;
}

// True when every line `span` touches is classified as `kind`. False for a span that straddles a
// blank line, straddles two different kinds, or touches no classified line at all (e.g. entirely
// inside a blank line) — inKind is meant for "is this safely and entirely inside a fence/heading/
// etc.", not a fuzzy overlap test.
export function inKind(ctx: MarkdownContext, span: Span, kind: MarkdownKind): boolean {
  let touched = false;
  for (const line of ctx.lines) {
    if (line.span.start >= span.end || line.span.end <= span.start) continue;
    touched = true;
    if (line.kind !== kind) return false;
  }
  return touched;
}
