// Claude's default connective tissue (issue #34) — phrase openers and transitions that announce a
// rhetorical move (restating, widening the lens, hedging, flagging an aside) instead of just making
// it. Wired through the claude-lexicon factory (rules/claude-lexicon.ts): ONE hit already fires,
// visibly; density only escalates the whole lexicon's defaultSeverity ("low") up to "medium" once
// the document reaches densityThreshold (3) hits — never a step-down.
//
// Two deliberate departures from the research thread's candidate list (issue #34 comments), noted
// here so the exclusion isn't silently lost:
//
//   - Bare "ultimately", "critically", "crucially", "subtly" are left OUT of this lexicon. They're
//     single adverbs reached for to make a claim sound weightier — the exact trope lex-magic-adverbs
//     (src/lint/lexicons/magic-adverbs.ts: "quietly", "deeply", "fundamentally", "remarkably",
//     "arguably") already covers, just with different words. Adding them here would just be the same
//     family under a different rule id; if magic-adverbs grows a Claude-specific variant later, that
//     lexicon is the place, not this one.
//
//   - "tl;dr" is written here as the single token "tldr", not the two-word phrase ["tl", "dr"]. The
//     tokenizer (stub-doc.ts's wordRe) never sees the semicolon as part of a word, and the unit
//     splitter (splitUnitSpans) treats ";" as a unit TERMINATOR — "TL;DR: ship it" splits into two
//     separate units ("TL;" and "DR: ship it") before word-scanning ever runs, so "tl" and "dr" can
//     never land in the same unit.words array for a multi-word entry to match contiguously. "tldr"
//     (no punctuation) is the form this matching engine can actually see; the semicolon spelling is
//     a known gap, not silently dropped.
//
// Consolidation-pass addition (issue #34): six more entries sourced from claudisms.ai (CC0), a
// crowdsourced list of Claude's written tics. "sit with" / "worth sitting with" and "double-click
// on" / "lean into" are Claude's reach for a physical-action metaphor over a plain verb ("consider",
// "look more closely at", "focus on"); "the question I keep coming back to" and "what I'd leave you
// with" are first-person framing devices for, respectively, opening on an unresolved thread and
// closing with one — connective tissue exactly like the rest of this file, so they join the same
// lexicon rather than starting a new one.
import type { Lexicon } from "./types.js";

export const claudeDiscourseMarkers: Lexicon = {
  id: "claude-discourse-markers",
  name: "Claude discourse markers",
  defaultSeverity: "low",
  densityThreshold: 3,
  entries: [
    { match: ["the", "key", "insight", "is"] },
    { match: ["the", "trick", "is"] },
    { match: ["the", "catch", "is"] },
    { match: ["the", "upshot"] },
    { match: ["put", "differently"] },
    { match: ["said", "differently"] },
    { match: ["in", "other", "words"] },
    { match: ["more", "concretely"] },
    { match: "concretely" },
    { match: ["zooming", "out"] },
    { match: ["taking", "a", "step", "back"] },
    { match: ["at", "a", "high", "level"] },
    { match: ["that", "said"] },
    { match: ["to", "be", "clear"] },
    { match: ["to", "be", "fair"] },
    { match: ["to", "be", "direct"] },
    { match: ["to", "be", "frank"] },
    { match: ["in", "practice"] },
    { match: ["in", "short"] },
    { match: ["in", "essence"] },
    { match: ["simply", "put"] },
    { match: ["long", "story", "short"] },
    { match: "net-net" },
    { match: ["worth", "calling", "out"] },
    { match: ["worth", "flagging"] },
    { match: ["one", "thing", "to", "note"] },
    { match: ["a", "few", "things", "to", "note"] },
    { match: ["key", "takeaways"] },
    { match: "tldr", note: "written form of \"tl;dr\" the tokenizer can actually see — see header comment" },
    { match: ["better", "posed"] },
    { match: ["sit", "with"], note: "claudisms.ai (CC0) — \"sit with that for a moment\"" },
    { match: ["worth", "sitting", "with"], note: "claudisms.ai (CC0)" },
    { match: ["the", "question", "i", "keep", "coming", "back", "to"], note: "claudisms.ai (CC0)" },
    { match: ["what", "i'd", "leave", "you", "with"], note: "claudisms.ai (CC0)" },
    { match: ["double-click", "on"], note: "claudisms.ai (CC0)" },
    { match: ["lean", "into"], note: "claudisms.ai (CC0)" },
  ],
};
