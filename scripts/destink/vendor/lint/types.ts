// Shared contracts for the de-stink linter (epic #28, step 0). Types only — no runtime code.
// Wave-1 modules build against these interfaces in parallel:
//   #7/#8  document splitter + parser-agnostic document path (produces DocUnit)
//   #9     analyzeDocument with source char offsets (produces DocAnalysis)
//   #10    copular/negation query helpers over the Clause IR (consumes Clause)
//   #11    TropeRule engine + runner (consumes DocAnalysis, produces Finding)

import type { Clause } from "../ir.js";
import type { Tree } from "../ptb.js";

// A half-open [start, end) character range into the ORIGINAL source text. For any span,
// text.slice(span.start, span.end) is the exact surface form — contractions, curly quotes and all.
export type Span = { start: number; end: number };

// One split unit of the document and what happened when we tried to parse + lower it.
// Fragments are data, not failures: verbless units ("Not a bug.") are the strongest trope signal.
export type UnitOutcome = "lowered" | "fragment" | "unparseable";

export type DocUnit = {
  unit: string; // the unit's raw text, exactly as sliced from the source
  span: Span; // where the unit sits in the original text
  outcome: UnitOutcome;
  clauses?: Clause[]; // present iff outcome === "lowered"
  reason?: string; // why lowering failed: the lower error message, or a root label like FRAG / no-VP
};

// A word with its source offsets. `text` is the SOURCE surface form for the span; tokenization may
// have normalized it (e.g. "won't" -> "wo" + "n't" as two entries mapping into one source word).
export type WordSpan = { text: string; span: Span; pos?: string };

// Per-unit analysis: the DocUnit outcome plus whatever the parse produced.
export type UnitAnalysis = DocUnit & {
  tree?: Tree; // constituency parse (fine POS tags at the leaves), when one was obtained
  words: WordSpan[]; // the unit's words in order, each mapped to source offsets
};

// The whole document, analyzed. Rules see all units in document order so cross-sentence patterns
// (anaphora, the reframe) and density thresholds are first-class.
export type DocAnalysis = {
  text: string; // the original input, untouched
  units: UnitAnalysis[];
};

export type TropeTier = "lexical" | "syntactic" | "formatting" | "discourse";

// "candidate" marks structurally-narrowed suspects a rule can't confirm without semantics
// (e.g. false ranges, #19); the scorer weighs them below confirmed findings.
export type Severity = "candidate" | "low" | "medium" | "high";

export type Finding = {
  ruleId: string;
  span: Span; // the primary offending span in the original text
  severity: Severity;
  message: string; // names the pattern, briefly
  explanation: string; // teaches it — why this reads as a tell, in the free.ts hint-writing voice
};

// A trope rule: a predicate over the whole document that returns located findings.
// Same shape as the game's Condition with the polarity flipped.
export type TropeRule = {
  id: string;
  name: string;
  tier: TropeTier;
  detect(doc: DocAnalysis): Finding[];
};
