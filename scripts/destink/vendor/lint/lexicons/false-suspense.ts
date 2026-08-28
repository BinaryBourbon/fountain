// "Here's the Kicker" — false-suspense transitions promising a revelation before an unremarkable
// observation. Fixed phrases, essentially never used by accident.
import type { Lexicon } from "./types.js";

export const falseSuspense: Lexicon = {
  id: "lex-false-suspense",
  name: "False suspense",
  defaultSeverity: "medium",
  entries: [
    { match: ["here's", "the", "kicker"] },
    { match: ["here's", "the", "thing"] },
    { match: ["here's", "where", "it", "gets", "interesting"] },
    { match: ["here's", "what", "most", "people", "miss"] },
    { match: ["here's", "the", "deal"] },
  ],
};
