// claude/ai-leakage (issue #34) — assistant/tool boilerplate and leaked artifact strings.
//
// This scans doc.text DIRECTLY, not doc.units[].words. Every other tier's word-list matching
// (lexical.ts's entryHits, claude-lexicon.ts's factory) assumes the thing being matched tokenizes
// cleanly — whole words or contiguous runs of them. Half of what this rule looks for doesn't:
// "[cite: ", "(start_span)", the lenticular brackets 【】, a query string's "utm_source=" — these
// are punctuation-bearing substrings and a URL fragment, not word tokens. Scanning the raw string
// keeps the matching honest instead of forcing it through a tokenizer it wasn't built for.
//
// Tier: filed as "lexical", not "formatting". The formatting tier (formatting.ts) is organized
// around the document's SHAPE — headings, lists, fences, paragraphs. This rule doesn't care about
// shape; it's a phrase/string presence check, the same organizing idea as every other file in the
// lexical tier, just matched over raw text instead of tokens because the tokenizer can't carry
// these particular strings. The markdown-fence awareness below is a borrowed cross-cutting concern
// (formatting.ts and this file both call into markdown.ts), not the reason this rule exists.
//
// Two families, deliberately different severity philosophies:
//
// FAMILY A — leaked tool/citation artifacts (oaicite, contentReference, turn0search, lenticular
// brackets, a tracked "utm_source=" pasted in from a share link...). These are copy-paste residue
// from an assistant's UI chrome or a citation renderer, not something a person would type. Per
// #34's sensitivity decision: SINGLE HIT FIRES, no density gating anywhere in this family, severity
// "high". Inside a fenced code block the same string is still worth flagging — a leaked citation
// tag pasted into a code sample is still a leak — so family A is NOT suppressed in code fences, it
// is only downgraded to "low" there (documented per-artifact below).
//
// FAMILY B — assistant-register boilerplate ("as an AI language model", "I hope this helps"...).
// These are English phrases a human could in principle type, just not ones a person drafting their
// own prose usually does — they're the shape of a chat reply, not of writing. Matched
// case-insensitively over raw text. Severity splits in two:
//   high    unambiguous machine-only phrasing: self-description ("as an AI language model"),
//           knowledge-cutoff disclosure (a chat assistant's job to say, never a writer's),
//           refusal/capability boilerplate, and the "certainly, here is/are" reply-opener.
//   medium  sign-off closers a human could plausibly write in their own words ("I hope this
//           helps", "let me know if you'd like me to...") — still a tell in finished prose, but a
//           softer one than the others, so it scores lower.
// Family B IS suppressed entirely inside code fences (a comment inside a code sample saying "I
// hope this helps" is not leakage, it's a comment).
//
// Quoted-mention decision (documented per #34's ask): a sentence that mentions one of these phrases
// in quotes to talk ABOUT AI detection ("the phrase 'as an AI language model' is a classic tell")
// still fires. This rule flags the STRING, not the author's intent — a linter that tried to guess
// "is this quoted-and-therefore-meta" would need to parse quotation scope reliably, which raw
// substring matching can't do without a lot of new surface area for a rare case. The recommended
// call from #34 is the simple one: the linter points at the string, the author decides whether it's
// actually a problem in context. See fixtures/claude-ai-leakage.ts's "fires even when the phrase is
// being discussed, not authored" positive.

import type { DocAnalysis, Finding, Severity, Span, TropeRule } from "../types.js";
import { textAt, contains } from "../span.js";
import { markdownContext, inKind } from "../markdown.js";

const RULE_ID = "claude/ai-leakage";

// --- generic substring/regex finders -----------------------------------------------------------

type Finder = (text: string) => Span[];

// Every non-overlapping occurrence of `needle`. Case-folds both sides when `caseSensitive` is
// false; `needle.length` is used for the span end either way, which is only safe for ASCII
// needles (true of every literal below) since case-folding never changes an ASCII string's length.
function literal(needle: string, caseSensitive: boolean): Finder {
  return (text) => {
    const hay = caseSensitive ? text : text.toLowerCase();
    const n = caseSensitive ? needle : needle.toLowerCase();
    const hits: Span[] = [];
    let from = 0;
    for (;;) {
      const at = hay.indexOf(n, from);
      if (at < 0) break;
      hits.push({ start: at, end: at + needle.length });
      from = at + needle.length;
    }
    return hits;
  };
}

function regex(re: RegExp): Finder {
  return (text) => {
    const g = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    const hits: Span[] = [];
    for (const m of text.matchAll(g)) hits.push({ start: m.index!, end: m.index! + m[0].length });
    return hits;
  };
}

// "utm_source=" is only a tell when it sits inside a URL — a bare mention of the string in prose
// (documentation about tracking parameters, say) isn't a leaked link. A URL is approximated as an
// http(s):// run up to the first whitespace or an enclosing bracket/quote character, which is the
// same rough shape formatting.ts and markdown-adjacent code in this repo use for "a URL-looking
// token". The reported span is just the "utm_source=" substring, not the whole URL, so the finding
// points at the exact tell rather than the whole (possibly long) link.
const URL_RE = /https?:\/\/[^\s)\]}>"']+/g;
const UTM_KEY = "utm_source=";
const utmSourceInUrl: Finder = (text) => {
  const hits: Span[] = [];
  for (const m of text.matchAll(URL_RE)) {
    const url = m[0];
    const idx = url.indexOf(UTM_KEY);
    if (idx < 0) continue;
    const start = m.index! + idx;
    hits.push({ start, end: start + UTM_KEY.length });
  }
  return hits;
};

// --- family A: leaked tool/citation artifacts ---------------------------------------------------

const ARTIFACT_EXPLANATION =
  `This is a raw citation or file-upload tag from an assistant's UI (or a share-link tracking ` +
  `parameter) that got pasted straight into the text instead of being rendered or stripped out. ` +
  `It's not a style choice to fix, it's debris — delete the tag (and, for a tracking link, the ` +
  `"?utm_source=..." tail) and keep whatever it was attached to.`;

const ARTIFACTS: readonly { label: string; find: Finder }[] = [
  { label: "oaicite", find: literal("oaicite", true) },
  { label: "contentReference", find: literal("contentReference", true) },
  { label: "oai_citation", find: literal("oai_citation", true) },
  { label: "turn0search", find: literal("turn0search", true) },
  { label: "attributableIndex", find: literal("attributableIndex", true) },
  { label: "[cite: ", find: literal("[cite: ", true) },
  { label: "[span_", find: literal("[span_", true) },
  { label: "(start_span)", find: literal("(start_span)", true) },
  { label: "grok_card", find: literal("grok_card", true) },
  { label: "grok_render_citation_card_json", find: literal("grok_render_citation_card_json", true) },
  { label: "ppl-ai-file-upload", find: literal("ppl-ai-file-upload", true) },
  { label: "attached_file", find: literal("attached_file", true) },
  { label: ":::writing", find: literal(":::writing", true) },
  { label: "regenerate response", find: literal("regenerate response", false) }, // case-insensitive, per #34
  { label: "lenticular bracket", find: regex(/[【】]/g) }, // 【 】
  { label: "utm_source= in a URL", find: utmSourceInUrl },
];

// --- family B: assistant-register boilerplate ---------------------------------------------------

const KNOWLEDGE_CUTOFF_EXPLANATION =
  `A chat assistant discloses its training boundary; a person writing their own prose doesn't need ` +
  `to. This exact family of phrase is common enough to be a named tell — "as of my last knowledge ` +
  `update" alone showed up in roughly 49% of the flagged-paper sample in the Academ-AI study of ` +
  `AI-tells in scholarly writing (arXiv 2411.15218). Cut the disclosure; state what you know, or ` +
  `cite the source's actual date if that's what you mean.`;

const SELF_DESCRIPTION_EXPLANATION =
  `"As an AI language model..." announces what's speaking instead of answering — a leftover from a ` +
  `chat reply pasted in whole. Delete the sentence; what follows usually stands on its own.`;

const REFUSAL_EXPLANATION =
  `This is refusal or capability boilerplate a chat assistant produces when it can't or won't do ` +
  `something. It has no place in finished writing — its presence means a whole reply (or an error ` +
  `message) got copied in along with the part that was actually wanted.`;

const CERTAINLY_EXPLANATION =
  `"Certainly, here is/are..." is a chat assistant's stock reply opener, still stapled to the answer ` +
  `that followed it. Cut the opener and start with the sentence that was actually meant.`;

const CLOSER_EXPLANATION =
  `"I hope this helps", "let me know if you'd like me to...", "would you like me to expand" are how ` +
  `a chat assistant signs off and offers to keep going. A person could type one of these too, which ` +
  `is why it scores softer than the rest of this rule — but in finished prose it's still an ` +
  `unanswered invitation nobody asked for. Cut the line.`;

const BOILERPLATE: readonly { text: string; severity: Severity; explanation: string }[] = [
  // high — unambiguous machine-only phrasing
  { text: "as an AI language model", severity: "high", explanation: SELF_DESCRIPTION_EXPLANATION },
  { text: "as a language model, I", severity: "high", explanation: SELF_DESCRIPTION_EXPLANATION },
  { text: "as of my last knowledge update", severity: "high", explanation: KNOWLEDGE_CUTOFF_EXPLANATION },
  { text: "my last knowledge update", severity: "high", explanation: KNOWLEDGE_CUTOFF_EXPLANATION },
  { text: "up to my last training update", severity: "high", explanation: KNOWLEDGE_CUTOFF_EXPLANATION },
  { text: "my knowledge cutoff", severity: "high", explanation: KNOWLEDGE_CUTOFF_EXPLANATION },
  { text: "I don't have access to real-time", severity: "high", explanation: REFUSAL_EXPLANATION },
  { text: "I do not have personal", severity: "high", explanation: REFUSAL_EXPLANATION },
  { text: "I cannot fulfill this request", severity: "high", explanation: REFUSAL_EXPLANATION },
  { text: "I'm sorry, but as an AI", severity: "high", explanation: SELF_DESCRIPTION_EXPLANATION },
  { text: "certainly, here is", severity: "high", explanation: CERTAINLY_EXPLANATION },
  { text: "certainly, here are", severity: "high", explanation: CERTAINLY_EXPLANATION },
  // medium — closers a human could conceivably write
  { text: "I hope this helps", severity: "medium", explanation: CLOSER_EXPLANATION },
  { text: "let me know if you'd like me to", severity: "medium", explanation: CLOSER_EXPLANATION },
  { text: "would you like me to expand", severity: "medium", explanation: CLOSER_EXPLANATION },
];

// --- overlap cleanup -----------------------------------------------------------------------------

// "as of my last knowledge update" contains "my last knowledge update" as a substring, so both
// entries match the same sentence at overlapping offsets. Keep the outer (longer, more specific)
// finding and drop anything another finding fully contains — one tell, one finding, not two
// stacked on the same words.
function dropContained(findings: readonly Finding[]): Finding[] {
  return findings.filter(
    (f, i) =>
      !findings.some((g, j) => {
        if (i === j) return false;
        if (g.span.start === f.span.start && g.span.end === f.span.end) return i > j; // exact dupe: keep first
        return contains(g.span, f.span);
      }),
  );
}

export const aiLeakageRule: TropeRule = {
  id: RULE_ID,
  name: "AI leakage (artifacts + assistant boilerplate)",
  tier: "lexical",
  detect(doc: DocAnalysis): Finding[] {
    const ctx = markdownContext(doc.text);
    const findings: Finding[] = [];

    for (const artifact of ARTIFACTS) {
      for (const span of artifact.find(doc.text)) {
        const inFence = inKind(ctx, span, "codeFence");
        findings.push({
          ruleId: RULE_ID,
          span,
          severity: inFence ? "low" : "high",
          message: `leaked artifact — “${textAt(doc, span)}”${inFence ? " (in a code block)" : ""}`,
          explanation: ARTIFACT_EXPLANATION,
        });
      }
    }

    for (const phrase of BOILERPLATE) {
      for (const span of literal(phrase.text, false)(doc.text)) {
        if (inKind(ctx, span, "codeFence")) continue; // family B is suppressed in fences, not downgraded
        findings.push({
          ruleId: RULE_ID,
          span,
          severity: phrase.severity,
          message: `assistant boilerplate — “${textAt(doc, span)}”`,
          explanation: phrase.explanation,
        });
      }
    }

    const deduped = dropContained(findings);
    deduped.sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);
    return deduped;
  },
};
