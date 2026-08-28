// Corporate jargon (issue #34, consolidation pass) — boardroom/business-speak clichés. Not
// LLM-specific on their own (people said "circle back" long before ChatGPT), but they show up
// constantly in AI-generated business writing because the model has seen so much of it, and
// they're exactly the kind of thing CLAUDE.md's word-choice section is aimed at: a fancy stand-in
// for a plain statement. Wired through the standard step-down factory (rules/excess-vocabulary.ts's
// buildStandardLexiconRule), same as lexicons/excess-vocabulary.ts.
//
// Every entry is a fixed multi-word (or hyphen-compound) phrase, not a common standalone word — the
// false-positive rate for "move the needle" or "take this offline" showing up by accident is close
// to zero, so this fires at "medium" on a single hit with no density gating, the same design point
// as lex-filler-transitions/lex-false-suspense (see lexicons/types.ts's densityThreshold doc).
//
// DEDUP against lex-pedagogical-voice and lex-ornate-nouns (rules/lexical.ts, both ACTIVE): neither
// lexicon has any of the multi-word phrases below. Two entries share a PREFIX with an existing
// single-word ornate-nouns entry — "paradigm shift" starts with ornate-nouns' bare "paradigm", and
// claude-technical-vocabulary's "north star" is the first two tokens of "north star metric" — but a
// prefix match from an unrelated lexicon is expected, allowed overlap (engine.ts: "two tells can
// legitimately land on the same words... from different rules"), not the same lexicon entry fired
// twice. A literal duplicate would be adding a bare "paradigm" or "synergy" entry here; neither is
// present, since ornate-nouns already owns those.
import type { Lexicon } from "./types.js";

export const corporateJargon: Lexicon = {
  id: "corporate-jargon",
  name: "Corporate jargon",
  defaultSeverity: "medium",
  entries: [
    { match: ["actionable", "insights"] },
    { match: ["thought", "leadership"] },
    { match: ["pain", "points"] },
    { match: ["pain", "point"] },
    { match: ["move", "the", "needle"] },
    { match: ["low-hanging", "fruit"] },
    { match: ["paradigm", "shift"] },
    { match: ["deep", "dive"] },
    { match: ["value", "proposition"] },
    { match: ["key", "learnings"] },
    { match: ["circle", "back"] },
    { match: ["double", "down"] },
    { match: ["take", "this", "offline"] },
    { match: ["north", "star", "metric"] },
    { match: ["boil", "the", "ocean"] },
    { match: "best-in-class" },
    { match: ["at", "the", "end", "of", "the", "day"] },
  ],
};
