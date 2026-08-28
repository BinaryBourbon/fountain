// "Quietly" and Other Magic Adverbs — adverbs reached for to make a mundane description feel
// significant. All common words with plenty of literal, non-figurative uses, so low severity with
// density required.
import type { Lexicon } from "./types.js";

export const magicAdverbs: Lexicon = {
  id: "lex-magic-adverbs",
  name: "Magic adverbs",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    {
      match: "quietly",
      posGate: "adverb",
      note: "figurative sense (\"quietly powerful\"), not literal (\"spoke quietly\")",
    },
    { match: "deeply", posGate: "adverb" },
    { match: "fundamentally", posGate: "adverb" },
    { match: "remarkably", posGate: "adverb" },
    { match: "arguably", posGate: "adverb" },
  ],
};
