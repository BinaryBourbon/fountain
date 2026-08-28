// Claude fiction frames (issue #34) — stock sentence frames measured across Claude's fiction
// generations. Sourced from EQ-Bench's per-model creative-writing slop profiles
// (https://eqbench.com — the "Claude" model cards list these exact frames among the most
// over-represented phrases in Claude's fiction output) and cross-checked against sam-paech's
// slop-forensics corpus tooling (https://github.com/sam-paech/slop-forensics), which builds the
// EQ-Bench slop lists from bulk model generations. Paraphrase-informed, not vendored: nothing here
// is copied verbatim from a slop-forensics data file as a bulk list — each entry below was picked
// by hand because it recurs in Claude fiction specifically, then checked against the two data
// files fetched for this task (see corroboration notes below). Do not treat this file as a mirror
// of any upstream list.
//
// Corroboration against the two fetched files (both consulted, neither vendored wholesale):
//   - antislop-sampler's slop_phrase_prob_adjustments.json (Apache-2.0): floor-adjustment entries
//     (probability multiplier 0.03125, its lowest/most-confident value) that exactly match entries
//     below: "barely above a whisper", "for what seemed like an eternity", "little did he know",
//     and (as the 2-word core of the frame here) "shivers down"/"shivers up".
//   - slop-forensics' data/slop_list_trigrams.json (MIT), trigrams mined from bulk generations
//     with stopwords stripped: "voice barely audible" appears verbatim; "could shake feeling" and
//     "shake feeling something" corroborate the held-feeling frame; "something else something"
//     sits next to (not identical to) "something else entirely".
// Both lists are dominated by fantasy-name slop (elara, kael, oakhaven...) and single-word
// atmosphere nouns (tapestry, labyrinth, cacophony) that belong to other lexicons or aren't
// sentence frames at all — none of that is pulled in here; this file stays scoped to multi-word
// frames a Claude-written scene reaches for at a beat change.
//
// Every entry is a fixed multi-word phrase, not a common word — the false-positive rate for
// "little did she know" showing up by accident in ordinary prose is close to zero, which is why
// this lexicon (unlike claude-fiction-gestures) fires at "medium" on a single hit: see
// rules/claude-lexicon.ts for the single-hit-fires, escalation-only severity model this and its
// sibling lexicon both use.
import type { Lexicon } from "./types.js";

export const claudeFictionFrames: Lexicon = {
  id: "claude-fiction-frames",
  name: "Claude fiction frames",
  defaultSeverity: "medium",
  densityThreshold: 3,
  entries: [
    { match: ["something", "else", "entirely"] },
    { match: ["barely", "above", "a", "whisper"], note: "antislop floor entry (0.03125) — near-unmistakable" },
    { match: ["voice", "barely", "audible"], note: "verbatim in slop-forensics' trigram list" },
    {
      match: ["didn't", "know", "she", "was", "holding"],
      note: "the held-breath frame — \"a breath she didn't know she was holding\"",
    },
    { match: ["didn't", "know", "he", "was", "holding"], note: "the held-breath frame, he-variant" },
    { match: ["a", "breath", "she", "didn't", "know"], note: "the held-breath frame's opening half" },
    { match: ["smile", "didn't", "reach"] },
    { match: ["didn't", "reach", "his", "eyes"] },
    { match: ["didn't", "reach", "her", "eyes"] },
    { match: ["quiet", "for", "a", "long", "moment"] },
    { match: ["a", "sound", "like"] },
    { match: ["like", "a", "held", "breath"] },
    { match: ["trying", "to", "sound", "casual"] },
    { match: ["something", "flickered", "across"] },
    { match: ["something", "shifted", "in"] },
    { match: ["seen", "better", "days"] },
    {
      match: ["couldn't", "shake", "the", "feeling"],
      note: "slop-forensics trigrams: \"could shake feeling\", \"shake feeling something\"",
    },
    { match: ["for", "what", "seemed", "like", "an", "eternity"], note: "antislop floor entry (0.03125)" },
    { match: ["little", "did", "she", "know"] },
    { match: ["little", "did", "he", "know"], note: "antislop floor entry (0.03125)" },
    { match: ["the", "air", "was", "thick", "with"] },
    { match: ["sent", "shivers", "down"], note: "antislop floor entry \"shivers down\" (0.03125) is the 2-word core of this frame" },
    {
      match: ["a", "mix", "of"],
      note: "the weakest entry here — ordinary in non-fiction prose too — but the fiction-register cluster it keeps company with makes it worth flagging at the lexicon's default severity",
    },
    { match: ["eyes", "gleamed", "with"] },
    { match: ["knuckles", "whitened"] },
    { match: ["let", "out", "a", "breath"] },
  ],
};
