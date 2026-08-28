// The Signposted Conclusion — explicitly announcing a conclusion instead of letting the reader
// feel it. Legitimate in some formal essay conventions, so kept at low severity with density.
import type { Lexicon } from "./types.js";

export const signposts: Lexicon = {
  id: "lex-signposts",
  name: "Signposted conclusions",
  defaultSeverity: "low",
  densityThreshold: 2,
  entries: [
    { match: ["in", "conclusion"] },
    { match: ["to", "sum", "up"] },
    { match: ["in", "summary"] },
  ],
};
