// Claude stock frames (issue #34) — the LinkedIn/tech-post broetry register: urgency hooks,
// significance frames, process frames, and verdict/CTA closers that the existing claude-* lexicons
// miss. Motivated by a real post that scored near zero against claude-assistant-voice,
// claude-discourse-markers and claude-technical-vocabulary despite reading unmistakably
// AI-flavored. Wired through the claude-lexicon factory (rules/claude-lexicon.ts): ONE hit already
// fires, visibly, at defaultSeverity ("low"); density only ESCALATES the whole lexicon up to
// "medium" once the document reaches densityThreshold (3) hits — never a step-down. The four
// unmistakable broetry closers below are pinned "medium" (immune to escalation in both directions,
// same convention as every other claude-* lexicon's pinned entries).
//
// --- DEDUP: grepped against every existing lexicon's data file before adding anything here -------
//
//   - "matters because" (2-token: ["matters","because"]) OVERLAPS claude-assistant-voice's
//     ["this","matters","because"] (3-token) — the given brief's "matters because" bigram is the
//     generalized form of that lexicon's fixed opener ("This matters because...", "The shift
//     matters because...", "That matters because..." all share the tail two tokens). Verified
//     against the fixture battery's actual enforcement (fixture-battery.test.ts's "cross-rule
//     precision" describe block, and src/lint/fixtures/claude-assistant-voice.ts): the battery only
//     forbids a rule firing on ANOTHER rule's NEGATIVE fixtures; it does not check whether other
//     rules also fire on a POSITIVE fixture. claude-assistant-voice's fixtures.ts has exactly one
//     "matters because" occurrence and it is a POSITIVE ("This matters because the migration
//     touches billing data."), not a negative — grepped the whole src/lint tree for "matters
//     because" to confirm there is no negative fixture anywhere containing the phrase. Kept the
//     bigram as specified: both rules firing side-by-side on "This matters because X" is allowed by
//     the battery's actual contract and is arguably correct (the sentence really does carry both
//     tells at once).
//   - claude-discourse-markers.ts's "in other words" / "to be clear" / "at a high level" family,
//     claude-technical-vocabulary.ts's dev-vernacular, claude-fiction-frames.ts /
//     claude-fiction-gestures.ts's fiction-register frames, and every lex-* lexicon in
//     lexicons/index.ts's LEXICONS barrel (delve-family, false-suspense, filler-transitions,
//     invented-concept-labels, magic-adverbs, ornate-nouns, pedagogical-voice, serves-as-verbs,
//     signposts, stakes-inflation, superficial-ing-verbs, vague-attribution): grepped for every
//     phrase below (case-insensitive, substring) — no collisions.
//
// --- PRECISION CALLS made against the brief's raw candidate list --------------------------------
//
//   - Standalone "on the sidelines" was DROPPED as a separate entry from "stay on the sidelines".
//     Two reasons: (1) it is a strict token-subsequence of "stay on the sidelines", so on the
//     motivating sample ("...can't afford to stay on the sidelines.") both would fire at once,
//     producing 4 raw hits instead of the specified 3; (2) bare "on the sidelines" collides hard
//     with the ubiquitous LITERAL sports sense ("the coach stood on the sidelines", "she watched
//     from the sidelines") with no "stay" anywhere nearby. Keeping only the fuller "stay on the
//     sidelines" phrase both fixes the count and dodges the literal collision — see the
//     fixtures file's negative for "she sat on the sidelines during the match" (no "stay", so no
//     fire; a genuine negative, not a documented false-positive trade-off).
//   - "agree?" and "thoughts?" (bare one-word CTA questions) were DROPPED entirely. stub-doc.ts's
//     wordRe only tokenizes `[\p{L}\p{N}]+` runs (plus internal apostrophes/hyphens) — "?" is never
//     part of any WordSpan, so a literal `match: "agree?"` could never match anything and the only
//     way to catch the CTA sense at all would be the bare words "agree" / "thoughts". Both are
//     ordinary high-frequency words ("I agree with the plan", "sharing my thoughts on the merger",
//     and claude-fiction-frames.ts's own fixture text contains "agreed", one lemma-step from
//     "agree") — matching them bare would be a severe precision regression this tier's
//     never-steps-down severity model can't absorb. No token-level rule can distinguish "Agree?" as
//     a standalone one-word sentence from ordinary prose use without punctuation- or
//     position-awareness this lexicon layer doesn't have; left out rather than guessed at.
//   - Gapped forms ("bake governance into", "bake X into Y") are impossible for this engine — entries
//     are contiguous token runs (see lexicons/types.ts's matching-strategy note) and there is no
//     fixed word count between "bake" and "into" to fill. Skipped per the brief; kept only the
//     literal contiguous forms that actually recur: "baked into" and "built in from the start".
//   - Bare "baked in" (no "into") was DROPPED, not just left as "baked into" per the brief's
//     suggestion, because it collides with the literal cooking sense with nothing to gate on:
//     "the cake was baked in a pan" matches the bigram ["baked","in"] exactly as well as "the bias
//     was baked in from day one" does. "baked into" doesn't share that collision — English doesn't
//     say a cake was "baked into a pan" — so it stands in for the idiom alone. See the fixtures
//     file's negative for the cake sentence.
//   - "the case for" and "makes the case for" are BOTH kept, per the brief, even though "makes the
//     case for X" contains "the case for X" as a token subsequence and so double-fires on that
//     exact phrasing (two findings, nested spans, on one sentence). Unlike the sidelines case above,
//     nothing in the brief pins an exact finding count on a sentence containing both, so this is
//     left as an accepted, documented overlap rather than dropping either phrase — "the case for"
//     on its own ("there's a strong case for caution") is common enough in ordinary prose to be the
//     weakest entry in this lexicon, which is exactly why it rides plain defaultSeverity with no
//     escalation exemption, same trade-off claude-fiction-frames.ts documents for "a mix of".
import type { Lexicon } from "./types.js";

export const claudeStockFrames: Lexicon = {
  id: "claude-stock-frames",
  name: "Claude stock frames",
  defaultSeverity: "low",
  densityThreshold: 3,
  entries: [
    // --- urgency hooks --------------------------------------------------------------------
    { match: ["isn't", "slowing", "down"] },
    { match: ["isn't", "going", "anywhere"] },
    { match: ["can't", "afford", "to"] },
    {
      match: ["stay", "on", "the", "sidelines"],
      note: "the literal head verb \"stay\" is required — dodges the ubiquitous literal sports " +
        "sense (\"stood on the sidelines\") without it; see DEDUP header for why bare \"on the " +
        "sidelines\" isn't its own entry",
    },
    { match: ["wake-up", "call"] },
    { match: ["the", "stakes", "couldn't", "be", "higher"] },

    // --- significance frames ---------------------------------------------------------------
    {
      match: ["matters", "because"],
      note: "generalized form of claude-assistant-voice's \"this matters because\" — see DEDUP " +
        "header; also fires on \"the shift matters because\", \"that matters because\", etc.",
    },
    { match: ["makes", "the", "case", "for"] },
    {
      match: ["the", "case", "for"],
      note: "weakest entry here — ordinary in non-AI prose too (\"there's a strong case for " +
        "caution\") — kept per the brief; see DEDUP header for the deliberate overlap with " +
        "\"makes the case for\"",
    },
    { match: ["wasn't", "built", "for"] },
    { match: ["wasn't", "designed", "for"] },
    { match: ["the", "pace", "it", "brings"] },
    { match: ["here's", "why", "that", "matters"] },

    // --- process frames ----------------------------------------------------------------------
    { match: ["from", "day", "one"] },
    { match: ["after", "the", "fact"] },
    { match: ["humans", "in", "the", "loop"] },
    { match: ["human", "in", "the", "loop"] },
    {
      match: ["baked", "into"],
      note: "\"baked in\" (no \"into\") is deliberately absent — see DEDUP header's cake-pan " +
        "collision",
    },
    { match: ["built", "in", "from", "the", "start"] },

    // --- verdict / CTA frames ----------------------------------------------------------------
    { match: ["full", "stop"] },
    { match: ["plain", "and", "simple"] },
    { match: ["it's", "that", "simple"] },
    { match: ["let", "that", "sink", "in"], severity: "medium", note: "unmistakable broetry closer" },
    { match: ["read", "that", "again"], severity: "medium", note: "unmistakable broetry closer" },
    {
      match: ["most", "people", "won't", "read", "this", "far"],
      severity: "medium",
      note: "unmistakable broetry closer",
    },
    { match: ["if", "this", "resonates"] },
    { match: ["repost", "if"], severity: "medium", note: "unmistakable broetry closer" },
  ],
};
