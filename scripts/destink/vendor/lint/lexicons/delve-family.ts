// "Delve" and friends — CLAUDE.md's "Delve and Friends" section: delve went from an uncommon word
// to a staggering share of AI text, alongside a family of similarly overused vocabulary.
import type { Lexicon } from "./types.js";

export const delveFamily: Lexicon = {
  id: "lex-delve-family",
  name: "Delve and friends",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    {
      match: "delve",
      lemma: true,
      severity: "medium",
      note: "the most infamous AI tell; strong signal even on a single occurrence",
    },
    { match: "certainly", note: "filler intensifier, as in \"we certainly need to...\"" },
    { match: "utilize", lemma: true, note: "plain \"use\" almost always reads better" },
    {
      match: "leverage",
      posGate: "verb",
      lemma: true,
      note: "as a verb (\"leverage these frameworks\"); the noun (financial leverage) is fine",
    },
    { match: "robust", note: "vague intensifier standing in for a specific quality" },
    { match: "streamline", lemma: true },
    {
      match: "harness",
      posGate: "verb",
      lemma: true,
      note: "as a verb (\"harness the power of...\"); the noun (a climbing harness) is fine",
    },
  ],
};
