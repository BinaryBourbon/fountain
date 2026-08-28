// The "Serves As" Dodge — replacing a plain "is"/"are" with a pompous stand-in. Feeds issue #18's
// copular-dodge rule (src/lint's syntactic tier), which pairs this lexicon with the copular query
// helpers from #10 to confirm the word is standing in for a copula rather than used literally
// ("the sign marks the trailhead" is fine; "the plaque marks a turning point" is the dodge).
import type { Lexicon } from "./types.js";

export const servesAsVerbs: Lexicon = {
  id: "lex-serves-as-verbs",
  name: "Serves-as verbs",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    {
      match: ["serve", "as"],
      lemma: true,
      note: "lemma applies to the head verb: serves as / served as / serving as",
    },
    { match: ["stand", "as"], lemma: true, note: "lemma applies to the head verb: stands as / stood as" },
    { match: "mark", posGate: "verb", lemma: true },
    { match: "represent", posGate: "verb", lemma: true },
  ],
};
