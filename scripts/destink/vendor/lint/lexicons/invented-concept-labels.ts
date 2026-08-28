// Invented Concept Labels — abstract problem-nouns appended to a domain word to fake an
// established term ("the supervision paradox", "workload creep"). This lexicon holds only the
// suffix nouns; the domain-word + suffix adjacency pattern is a structural check wave-2 owns.
// These are common ordinary nouns with plenty of legitimate uses (including established compounds
// like "digital divide" or "power vacuum" that are NOT AI inventions), so they stay low severity
// with density required.
import type { Lexicon } from "./types.js";

export const inventedConceptLabels: Lexicon = {
  id: "lex-invented-concept-labels",
  name: "Invented concept labels",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    { match: "paradox", posGate: "noun" },
    { match: "trap", posGate: "noun" },
    { match: "creep", posGate: "noun" },
    { match: "divide", posGate: "noun", note: "watch for the established compound \"digital divide\"" },
    { match: "vacuum", posGate: "noun", note: "watch for the established compound \"power vacuum\"" },
    { match: "inversion", posGate: "noun" },
  ],
};
