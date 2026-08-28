// "Let's Break This Down" / "Think of It As..." — the teacher-student voice AI defaults to even
// for expert readers. "it's like a" is generic enough to need density; the rest are distinctive.
import type { Lexicon } from "./types.js";

export const pedagogicalVoice: Lexicon = {
  id: "lex-pedagogical-voice",
  name: "Pedagogical voice",
  defaultSeverity: "medium",
  entries: [
    { match: ["let's", "break", "this", "down"] },
    { match: ["let's", "unpack"] },
    { match: ["let's", "dive", "in"] },
    { match: ["let's", "explore"] },
    { match: ["think", "of", "it", "as"] },
    {
      match: ["it's", "like", "a"],
      severity: "low",
      note: "generic analogy opener; also appears in ordinary non-AI writing, so treat as low " +
        "confidence alone",
    },
  ],
};
