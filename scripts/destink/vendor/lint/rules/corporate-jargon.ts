// corporate-jargon (issue #34) — wires the corporate-jargon Lexicon (lexicons/corporate-jargon.ts)
// through the standard-tier factory (rules/standard-lexicon.ts). Every entry there is a distinctive
// multi-word phrase with no densityThreshold, so this rides the factory's default: a single hit
// fires at the lexicon's severity outright (no step-down applies when densityThreshold is unset).
import { buildStandardLexiconRule } from "./standard-lexicon.js";
import { corporateJargon } from "../lexicons/corporate-jargon.js";

const EXPLANATION =
  `"Move the needle", "low-hanging fruit", "circle back", "take this offline" are boardroom ` +
  `stand-ins for a plain statement — say what actually changed, what's easy, when you'll follow up, ` +
  `or that you'll answer later, instead of reaching for the meeting-room version of the sentence.`;

export const corporateJargonRule = buildStandardLexiconRule(corporateJargon, EXPLANATION);
