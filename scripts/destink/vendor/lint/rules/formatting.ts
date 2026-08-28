// Formatting tier (epic #28, #21) — parser-free, markdown-aware. These four rules read doc.text
// directly and lean on markdown.ts's markdownContext for structure; they do NOT read doc.units,
// because the formatting tier cares about the document's shape (headings, lists, fences,
// paragraphs), not its clauses. All four skip code fences entirely via inKind(ctx, span,
// "codeFence").
//
// One file for the tier because the rules share one markdownContext per detect() call and the
// shared helpers (word counting, code-fence filtering) are tiny — four files would mostly be
// import boilerplate. Split them out if a rule outgrows this.

import type { DocAnalysis, Finding, Severity, TropeRule } from "../types.js";
import type { MarkdownContext, ListBlock, Paragraph } from "../markdown.js";
import { markdownContext, inKind } from "../markdown.js";
import { spanning } from "../span.js";

// ---------------------------------------------------------------------------------------------
// em-dash density
// ---------------------------------------------------------------------------------------------
// Counts em dashes (—) and double-hyphens used as a dash (--) outside code fences, per 1000 words
// of the document (also outside code fences). One em dash is normal prose punctuation — the repo's
// own comments use them — so a lone hit never fires regardless of how short the document is: we
// require at least 2 occurrences before density even gets computed. Thresholds (per 1000 words):
//   < 1        no finding — could be one dash in a long document, not a pattern
//   1 to <3    low
//   3 to <6    medium  (the CLAUDE.md guidance's ">3/1000 medium" line)
//   >= 6       high
// Findings are emitted one per occurrence (so the UI can highlight each dash), all sharing the
// document-wide severity and a message that states the aggregate count and density.

const WORD_RE = /[\p{L}\p{N}]+/gu;
const DASH_RE = /—|--/g;

function countWordsOutsideFences(ctx: MarkdownContext): number {
  let count = 0;
  for (const m of ctx.text.matchAll(WORD_RE)) {
    const span = { start: m.index!, end: m.index! + m[0].length };
    if (!inKind(ctx, span, "codeFence")) count++;
  }
  return count;
}

function dashOccurrences(ctx: MarkdownContext): { start: number; end: number }[] {
  const hits: { start: number; end: number }[] = [];
  for (const m of ctx.text.matchAll(DASH_RE)) {
    const span = { start: m.index!, end: m.index! + m[0].length };
    if (!inKind(ctx, span, "codeFence")) hits.push(span);
  }
  return hits;
}

export const emDashDensityRule: TropeRule = {
  id: "formatting/em-dash-density",
  name: "Em-dash density",
  tier: "formatting",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const hits = dashOccurrences(ctx);
    if (hits.length < 2) return [];
    const words = countWordsOutsideFences(ctx);
    const density = words === 0 ? 0 : (hits.length / words) * 1000;
    if (density < 1) return [];
    const severity: Severity = density >= 6 ? "high" : density >= 3 ? "medium" : "low";
    const rounded = Math.round(density * 10) / 10;
    const message = `em dash — ${hits.length} in ~${words} words (${rounded}/1000)`;
    const explanation = `You use an em dash or double-hyphen ${hits.length} times across this document — about ${rounded} per 1000 words. One is a stylistic choice; this many reads as a tic AI writing leans on for every aside and pivot. Cut most of them and let sentences end, or split into two sentences instead of dashing on.`;
    return hits.map((span) => ({ ruleId: "formatting/em-dash-density", span, severity, message, explanation }));
  },
};

// ---------------------------------------------------------------------------------------------
// unicode decoration
// ---------------------------------------------------------------------------------------------
// Three categories, outside code fences: arrows (→ ⇒ etc.), smart/curly quotation marks used AS
// quotation marks (not the same codepoint used as an apostrophe in a contraction), and decorative
// symbols (emoji, dingbats, misc symbols). One finding per category per document — not one per
// character — because ten arrows in a diagram-ish list is one tell, not ten. Each finding's span
// covers the full range from the first to the last hit in that category (spanning()), and the
// message carries the per-character count. Any category with zero hits produces no finding.
//
// Smart-quote detection: “ ” (U+201C/201D) are unambiguous quotation marks — always counted. ‘
// (U+2018) is also unambiguous — an opening single quote is never an apostrophe. ’ (U+2019) is
// reused as BOTH a closing single quote and a typed apostrophe ("don't" autocorrected to "don't"
// with a curly mark). We only count ’ when it is NOT sitting between two letters (that shape is a
// contraction/possessive apostrophe, normal prose); a ’ preceded or followed by a non-letter is
// being used as a quotation mark.
// Arrows block (U+2190–U+21FF: →, ⇒, ⇔…), Supplemental Arrows-A (U+27F0–U+27FF), Supplemental
// Arrows-B (U+2900–U+297F). Written as \u{} escapes, not literal glyphs, so the range boundaries
// are auditable rather than dependent on how two arrow-ish glyphs happen to render.
const ARROW_RE = /[\u{2190}-\u{21FF}\u{27F0}-\u{27FF}\u{2900}-\u{297F}]/gu;
// Misc Symbols + Dingbats (U+2600–U+27BF: ☀ ✨ ✔ ➜…), Misc Symbols & Arrows (U+2B00–U+2BFF: ⬆ ★…),
// and the emoji-ish astral ranges (U+1F300–U+1FAFF).
const DECORATIVE_RE = /[\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{1F300}-\u{1FAFF}]/gu;
const CURLY_DOUBLE_RE = /[“”]/gu;
const CURLY_SINGLE_OPEN_RE = /‘/gu;
const CURLY_APOSTROPHE_OR_CLOSE_RE = /’/gu;
const LETTER = /\p{L}/u;

function findAll(text: string, re: RegExp, filter?: (index: number) => boolean): { start: number; end: number }[] {
  const hits: { start: number; end: number }[] = [];
  for (const m of text.matchAll(re)) {
    if (filter && !filter(m.index!)) continue;
    hits.push({ start: m.index!, end: m.index! + m[0].length });
  }
  return hits;
}

function isQuotationUse(text: string, index: number): boolean {
  const before = index > 0 ? text[index - 1]! : "";
  const after = index + 1 < text.length ? text[index + 1]! : "";
  return !(LETTER.test(before) && LETTER.test(after));
}

function outsideFences(ctx: MarkdownContext, hits: { start: number; end: number }[]): { start: number; end: number }[] {
  return hits.filter((h) => !inKind(ctx, h, "codeFence"));
}

export const unicodeDecorationRule: TropeRule = {
  id: "formatting/unicode-decoration",
  name: "Unicode decoration",
  tier: "formatting",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const text = doc.text;

    const arrows = outsideFences(ctx, findAll(text, ARROW_RE));
    const decorative = outsideFences(ctx, findAll(text, DECORATIVE_RE));
    const smartQuotes = outsideFences(
      ctx,
      [
        ...findAll(text, CURLY_DOUBLE_RE),
        ...findAll(text, CURLY_SINGLE_OPEN_RE),
        ...findAll(text, CURLY_APOSTROPHE_OR_CLOSE_RE, (i) => isQuotationUse(text, i)),
      ].sort((a, b) => a.start - b.start),
    );

    const findings: Finding[] = [];
    if (arrows.length > 0) {
      findings.push({
        ruleId: "formatting/unicode-decoration",
        span: spanning(arrows),
        severity: "low",
        message: `${arrows.length} unicode arrow${arrows.length === 1 ? "" : "s"} (→, ⇒…)`,
        explanation: `Arrows like → read as a deck slide, not prose. Real keyboards type "->" or just write the word: "leads to", "then".`,
      });
    }
    if (smartQuotes.length > 0) {
      findings.push({
        ruleId: "formatting/unicode-decoration",
        span: spanning(smartQuotes),
        severity: "low",
        message: `${smartQuotes.length} curly quotation mark${smartQuotes.length === 1 ? "" : "s"} ("smart quotes")`,
        explanation: `Curly “quotes” and ‘quotes’ are what a word processor autocorrects to, not what someone typing in a plain editor produces. Straight quotes read as typed, not generated.`,
      });
    }
    if (decorative.length > 0) {
      findings.push({
        ruleId: "formatting/unicode-decoration",
        span: spanning(decorative),
        severity: "low",
        message: `${decorative.length} decorative symbol${decorative.length === 1 ? "" : "s"}`,
        explanation: `Dingbats and emoji sprinkled into prose (✨, ★…) read as decoration standing in for something to say. Say the thing instead.`,
      });
    }
    return findings;
  },
};

// ---------------------------------------------------------------------------------------------
// bold-first bullets
// ---------------------------------------------------------------------------------------------
// A list where most items open with a bolded lead-in ("**Security**: ..." or "**Performance**
// improvements...") reads as generated documentation. One bolded lead-in in an otherwise varied
// list is just emphasis; the PATTERN is what's flagged, once, for the whole list — not per item.
// Fires when a list has >= 3 items AND >= 60% of them open with **...** (optionally followed by a
// colon).
const BOLD_LEAD_RE = /^\*\*[^*]+\*\*:?/;
const MIN_LIST_ITEMS = 3;
const BOLD_FRACTION_THRESHOLD = 0.6;

function boldLeadFraction(list: ListBlock, text: string): number {
  const bold = list.items.filter((item) => BOLD_LEAD_RE.test(text.slice(item.contentSpan.start, item.contentSpan.end))).length;
  return bold / list.items.length;
}

export const boldFirstBulletRule: TropeRule = {
  id: "formatting/bold-first-bullet",
  name: "Bold-first bullets",
  tier: "formatting",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const findings: Finding[] = [];
    for (const list of ctx.lists) {
      if (list.items.length < MIN_LIST_ITEMS) continue;
      const fraction = boldLeadFraction(list, doc.text);
      if (fraction < BOLD_FRACTION_THRESHOLD) continue;
      const boldCount = Math.round(fraction * list.items.length);
      findings.push({
        ruleId: "formatting/bold-first-bullet",
        span: list.span,
        severity: "medium",
        message: `bold-first bullets — ${boldCount}/${list.items.length} items open with **bold**`,
        explanation: `Almost every item in this list starts with a bolded word or phrase, like a spec sheet. One bolded lead-in is emphasis; a whole list of them is a template. Vary the openings, or drop the bold and let the sentence do the work.`,
      });
    }
    return findings;
  },
};

// ---------------------------------------------------------------------------------------------
// listicle in a trench coat
// ---------------------------------------------------------------------------------------------
// >= 3 consecutive prose paragraphs that each open with an ordinal phrase ("The first...", "The
// second wall is...", "Next,...", "Finally..."), case-insensitive. This is a listicle wearing
// paragraph clothes: a numbered list rewritten as prose so it doesn't look like a list. Fires once
// per run, spanning from the first paragraph in the run to the last.
const ORDINAL_RE = /^(the\s+)?(first|second|third|fourth|fifth|sixth|next|final|last)\b/i;

function opensWithOrdinal(p: Paragraph, text: string): boolean {
  return ORDINAL_RE.test(text.slice(p.span.start, p.span.end).trimStart());
}

export const listicleInTrenchCoatRule: TropeRule = {
  id: "formatting/listicle-in-trench-coat",
  name: "Listicle in a trench coat",
  tier: "formatting",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const findings: Finding[] = [];
    let run: Paragraph[] = [];

    const flush = () => {
      if (run.length >= 3) {
        const severity: Severity = run.length >= 4 ? "high" : "medium";
        findings.push({
          ruleId: "formatting/listicle-in-trench-coat",
          span: spanning(run),
          severity,
          message: `${run.length} consecutive paragraphs open with "The first/second/next..."`,
          explanation: `This is a numbered list wearing paragraph clothes — each paragraph exists only to announce its position in a sequence. Either make it an actual list, or drop the ordinal openers and let the content carry the order.`,
        });
      }
      run = [];
    };

    for (const p of ctx.paragraphs) {
      if (opensWithOrdinal(p, doc.text)) run.push(p);
      else flush();
    }
    flush();
    return findings;
  },
};
