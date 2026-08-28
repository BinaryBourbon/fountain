// Superficial Analyses — a dangling present-participle ("-ing") phrase tacked onto a sentence to
// inject shallow significance ("contributing to the region's rich cultural heritage"). Feeds issue
// #18's rule family: the trope is specifically the trailing VBG form, not the verb in general, so
// posGate: "verb" (which already covers VBG under the VB prefix) narrows the part of speech and
// wave-2's rule should further check the tag is exactly VBG and the participle phrase trails a
// clause. Low severity alone — these are ordinary verbs; the syntactic position is the real signal.
import type { Lexicon } from "./types.js";

export const superficialIngVerbs: Lexicon = {
  id: "lex-superficial-ing-verbs",
  name: "Superficial -ing verbs",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    { match: "highlight", posGate: "verb", lemma: true, note: "e.g. \"highlighting its importance\"" },
    { match: "underscore", posGate: "verb", lemma: true, note: "e.g. \"underscoring its role\"" },
    { match: "reflect", posGate: "verb", lemma: true, note: "e.g. \"reflecting broader trends\"" },
    { match: "contribute", posGate: "verb", lemma: true, note: "e.g. \"contributing to the development of...\"" },
    { match: "cement", posGate: "verb", lemma: true },
    { match: "shape", posGate: "verb", lemma: true, note: "\"shape\" is also a common noun; posGate restricts to verb use" },
    { match: "solidify", posGate: "verb", lemma: true },
  ],
};
