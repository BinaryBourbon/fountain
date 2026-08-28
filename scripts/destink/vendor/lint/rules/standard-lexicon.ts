// Shared factory for standalone lexicons that want the GENERIC lexical tier's severity philosophy
// (rules/lexical.ts's buildLexiconRule: density STEPS DOWN a sparse hit) but can't go through
// lexical.ts's own LEXICONS-driven pipeline, because that pipeline auto-builds one rule per entry
// in lexicons/index.ts's LEXICONS array and lexical.test.ts pins that array's exact rule count.
// Adding a lexicon there for this consolidation pass would both grow that hardcoded count (a wave-1
// test this pass doesn't own) and mix these words into the lexical tier's blanket exports.
//
// This is the "standard-tier" analogue of rules/claude-lexicon.ts's buildClaudeLexiconRule: same
// idea (one shared factory, several concrete rule files import it and supply a Lexicon + taught
// explanation), opposite severity direction. buildLexiconRule itself isn't exported from
// lexical.ts, so this reimplements its density step-down logic — about a dozen lines, not worth a
// bigger refactor of lexical.ts to share one function. It DOES reuse lexical.ts's entryHits (word
// boundaries, phrase matching, lemma, posGate — the actual matching semantics), so this file's only
// job is severity/density scoring, not re-deriving how a word gets found.
//
// See rules/lexical.ts's own header for the full density model this mirrors: a lexicon declares
// densityThreshold N; when total hits < N, every hit whose entry rides the lexicon's
// defaultSeverity (no per-entry override) is reported one severity step down, floored at
// "candidate"; an entry with an explicit severity is exempt in both directions.

import type { DocAnalysis, Finding, Severity, Span, TropeRule } from "../types.js";
import { textAt } from "../span.js";
import type { Lexicon, LexiconEntry } from "../lexicons/index.js";
import { entryHits } from "./lexical.js";

const SEVERITY_STEPS: readonly Severity[] = ["candidate", "low", "medium", "high"];

function stepDown(s: Severity): Severity {
  const i = SEVERITY_STEPS.indexOf(s);
  return SEVERITY_STEPS[Math.max(0, i - 1)]!;
}

export function buildStandardLexiconRule(lexicon: Lexicon, explanation: string): TropeRule {
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

      const total = rawHits.length;
      const findings: Finding[] = rawHits.map(({ entry, span }) => {
        const base = entry.severity ?? lexicon.defaultSeverity;
        const belowDensity =
          entry.severity === undefined && lexicon.densityThreshold !== undefined && total < lexicon.densityThreshold;
        const severity = belowDensity ? stepDown(base) : base;
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
