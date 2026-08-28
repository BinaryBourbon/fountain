// excess-vocabulary (issue #34) — wires the excess-vocabulary Lexicon (lexicons/
// excess-vocabulary.ts) through the standard-tier factory (rules/standard-lexicon.ts): density
// STEPS DOWN a sparse hit, the opposite of the claude-lexicon.ts tier's escalation-only model. See
// that lexicon file's header for the full source attribution (Kobak et al. 2025, Juzek & Ward 2025)
// and the dedup decisions against every other lexicon in this directory.
import { buildStandardLexiconRule } from "./standard-lexicon.js";
import { excessVocabulary } from "../lexicons/excess-vocabulary.js";

const EXPLANATION =
  `"Delves", "showcasing", "underscores", "meticulously" and dozens of otherwise ordinary words ` +
  `like "pivotal", "intricate" and "invaluable" measurably show up far more often in text written ` +
  `with LLM assistance than in matched human baselines (Kobak et al. 2025, Science Advances; Juzek ` +
  `& Ward 2025, COLING). None of these words is wrong on its own — the tell is how often the same ` +
  `handful recur. Reach for the plainer word your own voice would use, or just say the thing ` +
  `directly.`;

export const excessVocabularyRule = buildStandardLexiconRule(excessVocabulary, EXPLANATION);
