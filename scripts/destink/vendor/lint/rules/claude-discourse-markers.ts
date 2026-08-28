// Claude discourse markers (issue #34) — wires the claude-discourse-markers Lexicon (lexicons/
// claude-discourse-markers.ts) through the claude-lexicon factory (single-hit fires visibly, density
// only escalates — see claude-lexicon.ts). All rule logic lives in the factory; this file only
// supplies the lexicon and the taught explanation.
import { buildClaudeLexiconRule } from "./claude-lexicon.js";
import { claudeDiscourseMarkers } from "../lexicons/claude-discourse-markers.js";

const EXPLANATION =
  `"The key insight is", "put differently", "zooming out", "to be clear" are Claude's default ` +
  `connective tissue — they announce a rhetorical move (restating, widening the lens, hedging) ` +
  `instead of just making it. One is easy to miss on its own; a page full of them reads like it was ` +
  `narrated by the same assistant every time. Cut the marker and let the sentence do the work it was ` +
  `announcing.`;

export const claudeDiscourseMarkersRule = buildClaudeLexiconRule(claudeDiscourseMarkers, EXPLANATION);
