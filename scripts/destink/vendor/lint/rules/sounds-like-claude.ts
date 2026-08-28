// claude/sounds-like-claude (issue #34) — the capstone. Every other claude-* rule in this
// directory flags ONE family of Claude-isms (chat-register phrases, dev-prose idiolect, discourse
// markers, fiction frames, fiction gestures, figurative suffixes, leaked artifacts, aphoristic
// enders, elegant variation, mirrored clauses). A document can
// trip any single one of those without reading as machine-written at all — a real engineer says
// "footgun" and "north star" without ever having talked to an AI. What's actually diagnostic is
// several DIFFERENT families showing up in the same document: that's not vocabulary, that's a
// voice. This rule is the document-level signal for that co-occurrence.
//
// Tier: "discourse", not "lexical" — like repetition.ts's dilution rule, this reasons over the
// WHOLE document's rule outputs, not over any one span of text. It has no lexicon of its own.
//
// WHY THE FAMILY RULES ARE IMPORTED DIRECTLY, NOT VIA registry.ts: registry.ts imports this file
// (to add soundsLikeClaudeRule to RULES); importing registry.ts back from here to enumerate
// "every rule whose id starts with claude" would be a straight import cycle. Importing the ten
// concrete rule objects directly below is both cycle-free and exactly equivalent in practice — the
// list below already covers every registered rule whose id starts "claude", including the three
// discourse-tier structural rules whose file headers also say "claude-isms tier, #34"
// (aphoristic-ender.ts, elegant-variation.ts, mirrored-clauses.ts) even though they don't live in
// this file's lexical neighborhood (checked against registry.ts by hand; the hygiene test in
// sounds-like-claude.test.ts re-checks it every run so this can't drift silently).
//
// WHY THE FAMILIES' OWN FINDINGS STILL APPEAR SEPARATELY (this rule is a CAPSTONE, not a
// replacement): a reader fixing "footgun" needs to know it's specifically the dev-prose idiolect
// that's the tell, with its own explanation and its own severity — collapsing that into one
// document-wide note would lose the "which word, where, why" specificity every other rule in this
// tier promises. This rule adds ONE extra signal on top — "the co-occurrence itself is the
// pattern" — it does not suppress or replace what the family rules already reported. (The engine's
// dedupe key is ruleId+span, so this rule's whole-document span under its own id never collides
// with anything the family rules reported under theirs.)
//
// DETERMINISM: family order below is fixed (declaration order, not discovery order), the message
// lists families in that same fixed order, and finding counts come straight from each family's own
// detect() — same doc in, same finding out, every run.
import type { DocAnalysis, Finding, TropeRule } from "../types.js";
import { aiLeakageRule } from "./ai-leakage.js";
import { aphoristicEnderRule } from "./aphoristic-ender.js";
import { claudeAssistantVoiceRule } from "./claude-assistant-voice.js";
import { claudeDiscourseMarkersRule } from "./claude-discourse-markers.js";
import { claudeFictionFramesRule, claudeFictionGesturesRule } from "./claude-fiction.js";
import { claudeFigurativeSuffixesRule } from "./claude-figurative.js";
import { contrastTailRule } from "./contrast-tail.js";
import { colonRevealRule } from "./colon-reveal.js";
import { claudeStockFramesRule } from "./claude-stock-frames.js";
import { claudeTechnicalVocabularyRule } from "./claude-lexicon.js";
import { elegantVariationRule } from "./elegant-variation.js";
import { mirroredClausesRule } from "./mirrored-clauses.js";

const RULE_ID = "claude/sounds-like-claude";

// Every registry.ts rule whose id starts "claude" — see the header note on why this is a direct
// list rather than a registry lookup. sounds-like-claude.test.ts's hygiene check keeps this honest.
const CLAUDE_FAMILIES: readonly TropeRule[] = [
  aiLeakageRule,
  aphoristicEnderRule,
  claudeAssistantVoiceRule,
  claudeDiscourseMarkersRule,
  claudeFictionFramesRule,
  claudeFictionGesturesRule,
  claudeFigurativeSuffixesRule,
  claudeStockFramesRule,
  claudeTechnicalVocabularyRule,
  colonRevealRule,
  contrastTailRule,
  elegantVariationRule,
  mirroredClausesRule,
];

// A document needs findings from at least this many DISTINCT families before the co-occurrence
// itself is worth flagging. Below this, any one (or two, or three) families firing alone is just
// that family's own finding(s) doing their job — see the file header.
const CO_OCCURRENCE_THRESHOLD = 4;

export const soundsLikeClaudeRule: TropeRule = {
  id: RULE_ID,
  name: "Sounds like Claude (family co-occurrence)",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const counts: { rule: TropeRule; count: number }[] = [];
    for (const rule of CLAUDE_FAMILIES) {
      const n = rule.detect(doc).length;
      if (n > 0) counts.push({ rule, count: n });
    }

    if (counts.length < CO_OCCURRENCE_THRESHOLD) return [];

    const breakdown = counts.map(({ rule, count }) => `${rule.id} (x${count})`).join(", ");
    const totalHits = counts.reduce((sum, { count }) => sum + count, 0);

    return [
      {
        ruleId: RULE_ID,
        span: { start: 0, end: doc.text.length },
        severity: "high",
        message: `${counts.length} distinct Claude-isms families co-occur in this document: ${breakdown}`,
        explanation:
          `Any one of these families alone is just a word choice — a real engineer says "footgun" ` +
          `without ever prompting an AI. But ${counts.length} different families (${totalHits} hits ` +
          `total) landing in the same document is a voice, not a vocabulary: ${breakdown}. Each ` +
          `finding above still points at its own specific phrase and family; this one flags the ` +
          `pattern of all of them showing up together. Read the piece for a consistent register in ` +
          `your own voice, not just word-by-word swaps.`,
      },
    ];
  },
};

// Hygiene check (issue #34's consolidation ask): CLAUDE_FAMILIES above must track "every registered
// rule whose id starts 'claude'" exactly. Importing registry.ts here (to compare against RULES)
// would reintroduce the cycle this file's header explains avoiding, so instead this exports the id
// set for a test file to import ALONGSIDE registry.ts and compare from the outside.
export const CLAUDE_FAMILY_IDS: ReadonlySet<string> = new Set(CLAUDE_FAMILIES.map((r) => r.id));
