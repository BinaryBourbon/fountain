// Claude stock frames (issue #34) — wires the claude-stock-frames Lexicon (lexicons/
// claude-stock-frames.ts) through the claude-lexicon factory (single-hit fires visibly, density
// only escalates — see claude-lexicon.ts). All rule logic lives in the factory; this file only
// supplies the lexicon and the taught explanation.
import { buildClaudeLexiconRule } from "./claude-lexicon.js";
import { claudeStockFrames } from "../lexicons/claude-stock-frames.js";

const EXPLANATION =
  `"Isn't slowing down", "can't afford to", "makes the case for", "from day one", "let that sink ` +
  `in" — the LinkedIn/tech-post broetry register: a hook that manufactures urgency, a frame that ` +
  `announces significance instead of showing it, and a closer built to farm engagement. Even one of ` +
  `these reads as a template running rather than a person writing. Say the actual claim, skip the ` +
  `hook and the sign-off.`;

export const claudeStockFramesRule = buildClaudeLexiconRule(claudeStockFrames, EXPLANATION);
