// "It's Worth Noting" — filler transitions that introduce a point without connecting it to
// anything. Distinctive enough that a single occurrence is already a decent signal.
import type { Lexicon } from "./types.js";

export const fillerTransitions: Lexicon = {
  id: "lex-filler-transitions",
  name: "Filler transitions",
  defaultSeverity: "medium",
  entries: [
    { match: ["it's", "worth", "noting"] },
    { match: ["it", "bears", "mentioning"] },
    { match: "importantly" },
    { match: "interestingly" },
    { match: "notably" },
  ],
};
