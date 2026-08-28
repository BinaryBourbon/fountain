// Claude assistant voice (issue #34) — wires the claude-assistant-voice Lexicon (lexicons/
// claude-assistant-voice.ts) through the claude-lexicon factory (single-hit fires visibly, density
// only escalates — see claude-lexicon.ts). All rule logic lives in the factory; this file only
// supplies the lexicon and the taught explanation.
import { buildClaudeLexiconRule } from "./claude-lexicon.js";
import { claudeAssistantVoice } from "../lexicons/claude-assistant-voice.js";

const EXPLANATION =
  `"You're absolutely right", "great question", "happy to elaborate", "feel free to" are Claude's ` +
  `chat register — reflexive validation and customer-service phrases meant for a live back-and-forth ` +
  `with a user, not a written document. Even one reads as a bot's voice bleeding through; cut the ` +
  `phrase and state the point directly instead of validating or offering to help.`;

export const claudeAssistantVoiceRule = buildClaudeLexiconRule(claudeAssistantVoice, EXPLANATION);
