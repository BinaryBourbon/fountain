// Shared data shape for the lexical tier of the de-stink linter (issue #20, wave 1). Data only —
// no matching logic, no rule wiring. Wave-2's TropeRules (issue #18 and friends) import LEXICONS
// from ./index.js, walk DocAnalysis/UnitAnalysis themselves, and decide how each entry becomes a
// Finding. Nothing here touches src/lint/types.ts or the rule engine.

import type { Severity } from "../types.js";

// POS gate, mapped onto the Penn Treebank tagset used by src/ptb.ts (the tags that appear at the
// leaves of a Tree, and on WordSpan.pos once a wave-2 rule threads POS through to word spans). A
// gate matches when the observed tag's first two letters equal the gate's PTB prefix below:
//
//   gate         PTB prefix   covers
//   "verb"       VB           VB, VBD, VBG, VBN, VBP, VBZ
//   "noun"       NN           NN, NNS, NNP, NNPS
//   "adverb"     RB           RB, RBR, RBS
//   "adjective"  JJ           JJ, JJR, JJS
//
// Ungated entries (no posGate) match regardless of tag. That's the right default for multi-word
// phrases — POS-gating a single token inside a fixed phrase rarely buys anything — and for words
// whose trope sense isn't tied to one part of speech.
export type PosGate = "verb" | "noun" | "adverb" | "adjective";

// The authoritative gate -> PTB-prefix mapping described above. The lexicon hygiene test asserts
// every PosGate value used anywhere in LEXICONS has an entry here, so this table can't silently
// drift out of sync with the entries that reference it.
export const POS_GATE_PREFIX: Record<PosGate, string> = {
  verb: "VB",
  noun: "NN",
  adverb: "RB",
  adjective: "JJ",
};

// One trigger inside a lexicon.
export type LexiconEntry = {
  // A single word, or a multi-word phrase given as a lowercase token sequence, e.g.
  // ["here's", "the", "kicker"]. This field fixes *what* the phrase is, not how it's tokenized or
  // located in source text — see the matching-strategy note below, which is wave-2's job to act on.
  match: string | string[];
  // Restricts the match to a word carrying this POS — e.g. "leverage" as a verb, not the finance
  // noun. Only meaningful for single-word `match`; ignored (and should be omitted) for phrases.
  posGate?: PosGate;
  // When true, match inflections of the word (delve/delves/delving/delved), not just the literal
  // string. For a phrase, this applies to the phrase's head verb (see per-file notes). Wave-2 owns
  // the actual lemmatizer/stemmer call — this is a boolean data flag, nothing more.
  lemma?: boolean;
  // Per-entry severity override. Falls back to the lexicon's defaultSeverity when omitted.
  severity?: Severity;
  // Short human-readable gloss. Wave-2 can fold this into Finding.explanation.
  note?: string;
};

// A themed group of entries: one AI-writing trope family from /Users/alex/.claude/CLAUDE.md
// (the tropes.fyi list).
export type Lexicon = {
  // Stable slug, referenced by TropeRule.id in wave-2 (e.g. "lex-delve-family"). Must be unique
  // across LEXICONS — enforced by the hygiene test.
  id: string;
  // Human label, e.g. "Delve and friends".
  name: string;
  // Severity for entries that don't specify their own `severity`.
  defaultSeverity: Severity;
  // A single hit is often fine — CLAUDE.md itself says as much: "any of these patterns used once
  // might be fine... the problem is when multiple appear together or a single trope is used
  // repeatedly." That's sharpest for lexicons built from ordinary words ("robust", "quietly",
  // "represent") that have plenty of innocent, non-trope uses. densityThreshold is a hint for
  // wave-2's scoring — the minimum occurrence count within one document before this lexicon's
  // entries (that don't carry their own high-confidence `severity` override) should be scored at
  // all. Omitted means every occurrence is already a strong enough signal on its own — typical for
  // lexicons built from distinctive multi-word phrases ("here's the kicker") that rarely occur by
  // accident.
  densityThreshold?: number;
  entries: LexiconEntry[];
};

// Matching-strategy note for wave-2 (proposed here, not implemented — the rule engine owns this):
//
//  - Case: all lexicon data below is lowercase. Match case-insensitively by lowercasing source
//    tokens before comparing; don't require the lexicon data itself to carry variants.
//  - Word boundaries: single-word entries should match whole words only, not substrings — "robust"
//    must not match inside "robustness". Use the tokenizer's word boundaries (WordSpan / Tree
//    leaves), not a raw regex \b, so offsets line up with Span.
//  - Multi-word entries (`match: string[]`) are contiguous token sequences. Pick one tokenization
//    convention for contractions (e.g. "here's" as one token, matching this data) and apply it
//    consistently on both sides — the lexicon data and whatever tokenizer produces WordSpan[].
//  - lemma:true entries should match the entry's inflections via whatever lemmatizer/stemmer
//    wave-2 already has on hand (compromise is already a dependency and does this).
//  - posGate should be checked against WordSpan.pos / the Tree leaf tag using POS_GATE_PREFIX,
//    e.g. `tag.startsWith(POS_GATE_PREFIX[entry.posGate])`.
//  - Figurative-sense notes (e.g. "landscape (figurative)", "quietly (figurative)") flag word
//    senses no POS tag distinguishes. Wave-2 will need either a heuristic (collocation list,
//    embedding check) or to accept some false positives/negatives here — that's a design call for
//    the rule author, not resolved by this data module.
