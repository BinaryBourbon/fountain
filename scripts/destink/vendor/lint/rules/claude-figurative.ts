// claude/figurative-suffixes (issue #34) — pattern-shaped Claude-isms the plain word-list lexicon
// factory (claude-lexicon.ts) can't express: a productive suffix turning an abstract noun into a
// figurative descriptor, a narrative frame borrowed for a technical process, and the literal-sense
// gate for "load-bearing" (deliberately excluded from lexicons/claude-technical-vocabulary.ts — see
// that file's header comment). All four checks share this file because none of them is a fixed
// phrase; each needs either a suffix decomposition or a look at a neighboring word.
//
// Tokenization note: stub-doc's wordRe (src/lint/stub-doc.ts) keeps an internal hyphen attached to
// its neighbors, so "agent-shaped", "load-bearing", "crypto-adjacent" and "JSON-flavored" each
// arrive as ONE WordSpan, not two tokens split on the hyphen. Every check below relies on that —
// there is no token-splitting here, just a suffix check on the single word's text.
//
// Allowlists are small and hand-picked, same spirit as dead-metaphor.ts's COMMON_WORDS: good enough
// to keep the obvious literal cases ("a star-shaped cookie", "cherry-flavored candy") clean without
// pretending to be exhaustive.

import type { DocAnalysis, Finding, Severity, Span, TropeRule, WordSpan } from "../types.js";
import { spanning, textAt } from "../span.js";

const RULE_ID = "claude/figurative-suffixes";

// Real physical shapes stay clean before "-shaped": "a star-shaped cookie", "an L-shaped desk".
// Anything else riding "-shaped" onto an abstract noun ("agent-shaped", "API-shaped", "a Y-shaped
// hole in the org") is the figurative tell.
const SHAPE_ALLOWLIST = new Set(["star", "heart", "egg", "pear", "l", "u", "v", "wedge"]);

// Food words before "-flavored" stay clean: "cherry-flavored candy". Anything else
// ("JSON-flavored") borrows "flavor" for something with no actual flavor.
const FLAVOR_ALLOWLIST = new Set([
  "cherry", "vanilla", "chocolate", "strawberry", "mint", "lemon", "lime", "orange", "grape",
  "banana", "coconut", "caramel", "cinnamon", "coffee", "raspberry", "blueberry", "apple",
  "peach", "mango", "watermelon", "honey", "maple",
]);

// "the X story" stays clean when X names an actual narrative genre. Anything else ("the deployment
// story", "the error-handling story") is a technical process wearing a narrative frame.
const STORY_LEGIT = new Set(["love", "ghost", "origin", "news", "cover", "short", "bedtime", "document"]);

// "load-bearing" stays literal — and clean — immediately before a structural noun.
const STRUCTURAL_NOUNS = new Set([
  "wall", "walls", "beam", "beams", "column", "columns",
  "pillar", "pillars", "structure", "structures", "member", "members",
]);

// True when `lower` ends in `suffix` and has at least one character of base left before it.
function stripSuffix(lower: string, suffix: string): string | null {
  if (lower.length <= suffix.length || !lower.endsWith(suffix)) return null;
  return lower.slice(0, -suffix.length);
}

type Kind = "shaped" | "adjacent" | "flavored" | "story" | "loadBearing";

const EXPLANATIONS: Record<Kind, string> = {
  shaped:
    `A productive "-shaped" bolted onto an abstract noun ("agent-shaped", "a Y-shaped hole in the ` +
    `org") describes a gap or a role by analogy to geometry it doesn't have. Name the actual gap ` +
    `instead — what's missing, or what would fill it.`,
  adjacent:
    `"-adjacent" tacked onto a domain word ("crypto-adjacent") gestures at a relationship without ` +
    `naming it. Say how the two things actually relate.`,
  flavored:
    `"-flavored" borrowed for something with no actual flavor ("JSON-flavored", "Rust-flavored") ` +
    `stands in for a real comparison. Say what it specifically resembles, or drop the metaphor.`,
  story:
    `"the X story" borrows a narrative frame for a technical process ("the deployment story", ` +
    `"the error-handling story"). Describe the process directly — there's usually a checklist, not ` +
    `a story.`,
  loadBearing:
    `"load-bearing" applied to code, a decision, or a person — not an actual wall or beam — is ` +
    `reached for to make "important" sound structural. Say what specifically breaks if it's removed.`,
};

const LABELS: Record<Kind, string> = {
  shaped: `"-shaped"`,
  adjacent: `"-adjacent"`,
  flavored: `"-flavored"`,
  story: `"the X story"`,
  loadBearing: `"load-bearing" (figurative)`,
};

function makeFinding(span: Span, severity: Severity, matchedText: string, kind: Kind): Finding {
  return {
    ruleId: RULE_ID,
    span,
    severity,
    message: `${LABELS[kind]}: "${matchedText}"`,
    explanation: EXPLANATIONS[kind],
  };
}

export const claudeFigurativeSuffixesRule: TropeRule = {
  id: RULE_ID,
  name: "Figurative suffixes and the load-bearing gate",
  tier: "lexical",
  detect(doc: DocAnalysis): Finding[] {
    const findings: Finding[] = [];

    for (const unit of doc.units) {
      const words: WordSpan[] = unit.words;

      for (let i = 0; i < words.length; i++) {
        const w = words[i]!;
        const lower = w.text.toLowerCase();

        const shapeBase = stripSuffix(lower, "-shaped");
        if (shapeBase !== null) {
          if (!SHAPE_ALLOWLIST.has(shapeBase)) findings.push(makeFinding(w.span, "medium", w.text, "shaped"));
          continue;
        }

        const adjacentBase = stripSuffix(lower, "-adjacent");
        if (adjacentBase !== null) {
          findings.push(makeFinding(w.span, "medium", w.text, "adjacent"));
          continue;
        }

        const flavorBase = stripSuffix(lower, "-flavored");
        if (flavorBase !== null) {
          if (!FLAVOR_ALLOWLIST.has(flavorBase)) findings.push(makeFinding(w.span, "medium", w.text, "flavored"));
          continue;
        }

        if (lower === "load-bearing") {
          const next = words[i + 1];
          const nextIsStructural = next !== undefined && STRUCTURAL_NOUNS.has(next.text.toLowerCase());
          if (!nextIsStructural) findings.push(makeFinding(w.span, "high", w.text, "loadBearing"));
          continue;
        }
      }

      for (let i = 0; i + 2 < words.length; i++) {
        const a = words[i]!;
        const b = words[i + 1]!;
        const c = words[i + 2]!;
        if (a.text.toLowerCase() !== "the" || c.text.toLowerCase() !== "story") continue;
        if (STORY_LEGIT.has(b.text.toLowerCase())) continue;
        const span = spanning([a, b, c]);
        findings.push(makeFinding(span, "medium", textAt(doc, span), "story"));
      }
    }

    findings.sort((p, q) => p.span.start - q.span.start || p.span.end - q.span.end);
    return findings;
  },
};
