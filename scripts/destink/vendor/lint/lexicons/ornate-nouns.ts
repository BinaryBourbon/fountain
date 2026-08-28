// "Tapestry" and "Landscape" — ornate or grandiose nouns standing in for something plainer.
import type { Lexicon } from "./types.js";

export const ornateNouns: Lexicon = {
  id: "lex-ornate-nouns",
  name: "Ornate nouns",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    { match: "tapestry", severity: "medium", note: "\"the rich tapestry of X\"; rarely used literally" },
    {
      match: "landscape",
      note: "figurative sense only (\"the landscape of modern AI\"); wave-2 needs to exclude " +
        "literal geography/terrain uses — see the matching-strategy note in ./types.ts",
    },
    { match: "paradigm" },
    { match: "synergy" },
    { match: "ecosystem" },
  ],
};
