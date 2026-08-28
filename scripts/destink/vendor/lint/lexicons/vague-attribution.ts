// Vague Attributions — claims pinned on unnamed "experts" or "observers" instead of a named
// source.
import type { Lexicon } from "./types.js";

export const vagueAttribution: Lexicon = {
  id: "lex-vague-attribution",
  name: "Vague attribution",
  defaultSeverity: "medium",
  entries: [
    { match: ["experts", "argue"] },
    { match: ["experts", "say"] },
    { match: ["observers", "have", "cited"] },
    { match: ["industry", "reports", "suggest"] },
  ],
};
