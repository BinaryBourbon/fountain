// Grandiose Stakes Inflation — every argument gets inflated to world-historical significance.
import type { Lexicon } from "./types.js";

export const stakesInflation: Lexicon = {
  id: "lex-stakes-inflation",
  name: "Stakes inflation",
  defaultSeverity: "medium",
  entries: [
    { match: ["fundamentally", "reshape"] },
    { match: ["will", "define", "the", "next", "era"] },
    { match: ["entirely", "new"] },
  ],
};
