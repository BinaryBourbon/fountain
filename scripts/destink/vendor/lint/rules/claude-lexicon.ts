// Factory for the claude-isms lexicon rules (issue #34). Same matching semantics as the generic
// lexical tier (entryHits from lexical.ts: case-folded whole tokens, contiguous phrases, narrow
// lemma suffixes, fail-closed posGate) — but the OPPOSITE severity philosophy, by owner decision
// on #34:
//
//   ONE HIT FIRES, VISIBLY. Claude's dialect has spread widely enough into human prose that a
//   single marker phrase is already the tell. There is NO below-threshold step-down (the generic
//   tier demotes sparse hits toward "candidate"; this tier never does). Density only ESCALATES:
//   when a lexicon declares densityThreshold N and the document reaches N total hits from that
//   lexicon, every hit riding the lexicon's defaultSeverity steps UP one level, capped at "high".
//   Entries with an explicit severity are pinned there in both directions, same as the generic
//   tier.
//
// The claim a finding makes is about the PHRASE, never the author: "this reads as Claude-flavored
// and is worth rewording" — explanations must teach, not accuse (see #34's non-goals).

import type { DocAnalysis, Finding, Severity, Span, TropeRule } from "../types.js";
import { textAt } from "../span.js";
import type { Lexicon, LexiconEntry } from "../lexicons/index.js";
import { entryHits } from "./lexical.js";
import { claudeTechnicalVocabulary } from "../lexicons/claude-technical-vocabulary.js";

const SEVERITY_STEPS: readonly Severity[] = ["candidate", "low", "medium", "high"];

function stepUp(s: Severity): Severity {
  const i = SEVERITY_STEPS.indexOf(s);
  return SEVERITY_STEPS[Math.min(SEVERITY_STEPS.length - 1, i + 1)]!;
}

export function buildClaudeLexiconRule(lexicon: Lexicon, explanation: string): TropeRule {
  return {
    id: lexicon.id,
    name: lexicon.name,
    tier: "lexical",
    detect(doc: DocAnalysis): Finding[] {
      const rawHits: { entry: LexiconEntry; span: Span }[] = [];
      for (const unit of doc.units) {
        for (const entry of lexicon.entries) {
          for (const span of entryHits(entry, unit.words)) rawHits.push({ entry, span });
        }
      }
      if (rawHits.length === 0) return [];

      const escalate = lexicon.densityThreshold !== undefined && rawHits.length >= lexicon.densityThreshold;
      const findings: Finding[] = rawHits.map(({ entry, span }) => {
        const base = entry.severity ?? lexicon.defaultSeverity;
        const severity = entry.severity === undefined && escalate ? stepUp(base) : base;
        return {
          ruleId: lexicon.id,
          span,
          severity,
          message: `${lexicon.name}: “${textAt(doc, span)}”`,
          explanation,
        };
      });

      findings.sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);
      return findings;
    },
  };
}

// --- the concrete rule (issue #34) ------------------------------------------------------------
// "load-bearing" is deliberately absent from claudeTechnicalVocabulary's data (see that file's
// header) — its literal-sense gate lives in rules/claude-figurative.ts, which the ungated entries
// below don't need.

const CLAUDE_TECHNICAL_VOCABULARY_EXPLANATION =
  `"Battle-tested", "footgun", "escape hatch", "happy path", "blast radius", "table stakes", ` +
  `"north star", "single source of truth", "cognitive load", "mental model", "guardrails", ` +
  `"seamless", "idiomatic", "opinionated" — this is Claude's dev-prose idiolect: real engineering ` +
  `words that show up so often in AI-written docs and PRs that one instance already reads as ` +
  `machine-flavored, whoever typed it. Swap in the plainer word your own voice would reach for, or ` +
  `just say what the thing does.`;

export const claudeTechnicalVocabularyRule: TropeRule = buildClaudeLexiconRule(
  claudeTechnicalVocabulary,
  CLAUDE_TECHNICAL_VOCABULARY_EXPLANATION,
);
