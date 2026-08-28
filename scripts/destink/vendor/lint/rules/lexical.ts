// The lexical tier (issue #20) — one TropeRule per word-list Lexicon in ../lexicons/index.ts. Each
// rule scans doc.units[].words for its lexicon's entries and reports a Finding per hit. This file
// is the "wave-2" half of issue #20: the lexicon data files fix WHAT the trigger words are; this
// file decides HOW a WordSpan[] gets checked against them and what a hit is worth.
//
// Two lexicons are skipped here on purpose: lex-serves-as-verbs and lex-superficial-ing-verbs feed
// issue #18's syntactic rules (they need the copular-dodge query helpers and a trailing-VBG
// position check respectively — a plain word-list scan over-fires on both, per their own file
// comments). Building a lexical rule for them here would just get thrown away when #18 lands its
// real version, so they are left out of LEXICAL_RULES and out of the registry.
//
// ---------------------------------------------------------------------------------------------
// MATCHING SEMANTICS (the spec this file implements — see lexicons/types.ts's proposal comment
// for the open questions this resolves):
//
//  Case            Every comparison lowercases the source WordSpan.text before comparing. Lexicon
//                  data is already lowercase (enforced by the hygiene test), so no case-folding is
//                  needed on that side.
//
//  Word boundary   A single-word `match` is compared against one whole WordSpan.text, never a
//                  substring — "robust" cannot match inside "robustness" because the tokenizer
//                  (stub-doc.ts's wordSpans, or the real analyzer's future equivalent) already
//                  produced "robustness" as one token distinct from "robust".
//
//  Multi-word      A `match: string[]` is a contiguous run of tokens: entry.match[0] must equal
//                  words[i], entry.match[1] must equal words[i+1], and so on with no gaps. The
//                  found span is spanning() over that exact slice of WordSpans, so it covers only
//                  the matched words and nothing around them.
//
//  Contractions    The lexicon data spells out contractions as one token — "it's", "here's" — on
//                  the assumption that the tokenizer does the same. stub-doc.ts's wordRe keeps an
//                  internal apostrophe attached to its neighbors ("it's" is one WordSpan, not
//                  "it" + "'s"), which is exactly the convention the data was written against, so
//                  multi-word entries like ["it's", "worth", "noting"] line up with zero special
//                  casing here. Any other tokenizer feeding this rule must keep that same
//                  convention or these entries silently stop matching.
//
//  lemma           A small, dependency-free suffix matcher (lemmaMatches, below) — not a stemmer
//                  library, just the regular-inflection patterns the lemma:true entries in these
//                  lexicons actually need: plain -s/-es, -ed/-ing with e-drop ("delve" ->
//                  "delving"), and y -> ies/ied ("deny" -> "denies"/"denied"; not exercised by the
//                  current data, kept for the next lexicon that needs it). It is deliberately
//                  narrow: it does not know irregular verbs. That's fine for every lemma:true entry
//                  in the lexicons this file actually builds rules for (all regular verbs); the one
//                  lexicon with an irregular form in its notes (lex-serves-as-verbs' "stand" ->
//                  "stood") is one of the two skipped above and is #18's problem. For a multi-word
//                  entry, lemma applies to the FIRST token only (the phrase's head verb), matching
//                  the per-file notes left on the data.
//
//  posGate         Checked against WordSpan.pos using POS_GATE_PREFIX: the gate passes when pos is
//                  present and starts with the gate's 2-letter prefix (e.g. a "verb" gate accepts
//                  any tag starting "VB": VB, VBD, VBG, VBN, VBP, VBZ). FAIL-CLOSED WHEN POS IS
//                  ABSENT: an entry with a posGate simply does not match a word that carries no
//                  pos at all, rather than treating "unknown" as "assume it passes". makeDoc (the
//                  stub analyzer used everywhere real parsing hasn't run yet) never fills pos, so
//                  every posGate'd entry is silent against stub documents until a real tagger is
//                  wired in. That trades recall for precision on purpose — a linter that guesses at
//                  a word's part of speech and is wrong reads as broken; one that stays quiet
//                  without evidence reads as careful. posGate is ignored on multi-word entries
//                  (the hygiene test already forbids the combination).
//
//  Figurative      A few entries (landscape, tapestry, invented-concept-label nouns, magic
//  senses          adverbs) flag a sense no POS tag distinguishes from an entirely innocent literal
//                  use ("the landscape of modern AI" vs. "hiked across the landscape"). This file
//                  does not attempt a collocation or embedding heuristic for that — per the data
//                  author's note, it's an accepted design trade this rule makes: these lexicons
//                  keep densityThreshold set specifically so an occasional literal false positive
//                  doesn't score high on its own, but they can still fire on a single literal use.
//
//  Severity        finding.severity = entry.severity ?? lexicon.defaultSeverity, then adjusted for
//                  density (below).
//
//  Density         CHOSEN SEMANTICS (the data author left this open in lexicons/types.ts): when a
//                  lexicon declares densityThreshold N, count every hit from every entry in that
//                  lexicon across the WHOLE document. If that total is below N, every hit whose
//                  entry did NOT specify its own `severity` (i.e. it's riding the lexicon's
//                  defaultSeverity) is reported one severity step lower than usual, floored at
//                  "candidate" (never negative, never dropped). At or above N, hits score at their
//                  normal severity. An entry with an explicit `severity` override is exempt from
//                  this downgrade in both directions — that override exists specifically to mark an
//                  entry as a strong-enough signal on its own regardless of density (e.g. "delve",
//                  whose note says as much). Steps run candidate < low < medium < high.
// ---------------------------------------------------------------------------------------------

import type { DocAnalysis, Finding, Severity, Span, TropeRule, WordSpan } from "../types.js";
import { spanning, textAt } from "../span.js";
import { LEXICONS, POS_GATE_PREFIX, type Lexicon, type LexiconEntry } from "../lexicons/index.js";

// Lexicons that feed issue #18's structural rules instead of getting a plain word-list scan here.
const STRUCTURAL_LEXICON_IDS = new Set(["lex-serves-as-verbs", "lex-superficial-ing-verbs"]);

// --- lemma matching ------------------------------------------------------------------------

// True when `word` is `base` or one of its regular inflections. See the file-level comment above
// for exactly which suffix patterns this covers and why that's enough for this data.
export function lemmaMatches(base: string, word: string): boolean {
  const b = base.toLowerCase();
  const w = word.toLowerCase();
  if (w === b) return true;

  if (/[^aeiou]y$/.test(b)) {
    // deny -> denies / denied (y -> ies/ied after a consonant). -ing keeps the y (denying), which
    // plain concatenation below already produces, so it isn't special-cased here.
    const stem = b.slice(0, -1);
    if (w === `${stem}ies` || w === `${stem}ied`) return true;
  } else if (w === `${b}s` || w === `${b}es`) {
    return true;
  }

  if (b.endsWith("e")) {
    // delve -> delved / delving (drop the trailing e before -ing; -ed just appends d).
    const stem = b.slice(0, -1);
    if (w === `${b}d` || w === `${stem}ing`) return true;
  } else if (w === `${b}ed` || w === `${b}ing`) {
    return true;
  }

  return false;
}

// --- entry matching -------------------------------------------------------------------------

function posGateFails(entry: LexiconEntry, word: WordSpan): boolean {
  if (!entry.posGate) return false;
  if (!word.pos) return true; // fail closed: no POS evidence, no match
  return !word.pos.startsWith(POS_GATE_PREFIX[entry.posGate]);
}

function singleWordHits(entry: LexiconEntry, match: string, words: WordSpan[]): Span[] {
  const hits: Span[] = [];
  for (const w of words) {
    const textMatches = entry.lemma ? lemmaMatches(match, w.text) : w.text.toLowerCase() === match;
    if (!textMatches) continue;
    if (posGateFails(entry, w)) continue;
    hits.push(w.span);
  }
  return hits;
}

function phraseHits(entry: LexiconEntry, tokens: string[], words: WordSpan[]): Span[] {
  const hits: Span[] = [];
  for (let i = 0; i + tokens.length <= words.length; i++) {
    let ok = true;
    for (let j = 0; j < tokens.length; j++) {
      const w = words[i + j]!;
      const isHead = j === 0;
      const wordMatches = isHead && entry.lemma ? lemmaMatches(tokens[j]!, w.text) : w.text.toLowerCase() === tokens[j];
      if (!wordMatches) {
        ok = false;
        break;
      }
    }
    if (ok) hits.push(spanning(words.slice(i, i + tokens.length)));
  }
  return hits;
}

// Exported for claude-lexicon.ts, which reuses the exact matching semantics with different
// severity semantics (single-hit, escalation-only — see that file).
export function entryHits(entry: LexiconEntry, words: WordSpan[]): Span[] {
  return Array.isArray(entry.match) ? phraseHits(entry, entry.match, words) : singleWordHits(entry, entry.match, words);
}

// --- severity / density ----------------------------------------------------------------------

const SEVERITY_STEPS: readonly Severity[] = ["candidate", "low", "medium", "high"];

function stepDown(s: Severity): Severity {
  const i = SEVERITY_STEPS.indexOf(s);
  return SEVERITY_STEPS[Math.max(0, i - 1)]!;
}

// --- rule factory ----------------------------------------------------------------------------

function buildLexiconRule(lexicon: Lexicon, explanation: string): TropeRule {
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
        const matchedText = textAt(doc, span);
        return {
          ruleId: lexicon.id,
          span,
          severity,
          message: `${lexicon.name}: “${matchedText}”`,
          explanation,
        };
      });

      findings.sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);
      return findings;
    },
  };
}

// --- per-lexicon explanations (free.ts hint voice: concrete, second person, one example, no
// lecture) — one per rule, reused for every finding that rule produces. -------------------------

const EXPLANATIONS: Record<string, string> = {
  "lex-delve-family": `"Delve", "utilize", "leverage", "robust", "streamline", "harness", "certainly" ` +
    `used to be uncommon words; AI writing wore them smooth. Swap in the plain version: delve becomes ` +
    `look into, utilize becomes use, leverage (as a verb) becomes use or draw on.`,
  "lex-ornate-nouns": `"Tapestry", "landscape", "paradigm", "synergy", "ecosystem" dress up an ordinary ` +
    `noun in a costume. Say what you mean instead: the field, not the landscape; the approach, not the ` +
    `paradigm.`,
  "lex-filler-transitions": `"It's worth noting", "it bears mentioning", "importantly", "interestingly", ` +
    `"notably" announce that a point is coming without connecting it to the one before. Cut the phrase ` +
    `and open with the point itself.`,
  "lex-false-suspense": `"Here's the kicker", "here's the thing", "here's where it gets interesting" ` +
    `promise a reveal, then land on something ordinary. State the fact and skip the drumroll.`,
  "lex-pedagogical-voice": `"Let's break this down", "let's unpack", "think of it as" switch into ` +
    `teacher mode even for a reader who already knows the material. Say the thing plainly and trust the ` +
    `reader to follow.`,
  "lex-signposts": `"In conclusion", "to sum up", "in summary" announce that the piece is ending instead ` +
    `of just ending it. A reader feels the last paragraph coming; you don't need to label it.`,
  "lex-stakes-inflation": `"Fundamentally reshape", "will define the next era", "entirely new" turn an ` +
    `ordinary claim into a world-historical one. Scale the language to match the actual claim.`,
  "lex-vague-attribution": `"Experts argue", "observers have cited", "industry reports suggest" pin a ` +
    `claim on nobody in particular. Name the source, or admit the claim is your own.`,
  "lex-invented-concept-labels": `"Paradox", "trap", "creep", "divide", "vacuum", "inversion" tacked onto ` +
    `a plain noun can dress up an ordinary observation as a named phenomenon, like "the supervision ` +
    `paradox". If the label isn't an established term, describe the thing instead of naming it.`,
  "lex-magic-adverbs": `"Quietly", "deeply", "fundamentally", "remarkably", "arguably" get reached for to ` +
    `make a mundane sentence feel weighty. Try the sentence without the adverb; if it loses nothing, ` +
    `that's the tell.`,
};

// --- the rules --------------------------------------------------------------------------------

const lexiconById = new Map(LEXICONS.map((l) => [l.id, l]));

function ruleFor(id: string): TropeRule {
  const lexicon = lexiconById.get(id);
  if (!lexicon) throw new Error(`lexical.ts: no lexicon registered with id ${id}`);
  const explanation = EXPLANATIONS[id];
  if (!explanation) throw new Error(`lexical.ts: no explanation written for ${id}`);
  return buildLexiconRule(lexicon, explanation);
}

// Alphabetical by rule id, matching how registry.ts orders them.
export const lexDelveFamilyRule = ruleFor("lex-delve-family");
export const lexFalseSuspenseRule = ruleFor("lex-false-suspense");
export const lexFillerTransitionsRule = ruleFor("lex-filler-transitions");
export const lexInventedConceptLabelsRule = ruleFor("lex-invented-concept-labels");
export const lexMagicAdverbsRule = ruleFor("lex-magic-adverbs");
export const lexOrnateNounsRule = ruleFor("lex-ornate-nouns");
export const lexPedagogicalVoiceRule = ruleFor("lex-pedagogical-voice");
export const lexSignpostsRule = ruleFor("lex-signposts");
export const lexStakesInflationRule = ruleFor("lex-stakes-inflation");
export const lexVagueAttributionRule = ruleFor("lex-vague-attribution");

export const LEXICAL_RULES: readonly TropeRule[] = LEXICONS.filter((l) => !STRUCTURAL_LEXICON_IDS.has(l.id)).map((l) =>
  ruleFor(l.id),
);
