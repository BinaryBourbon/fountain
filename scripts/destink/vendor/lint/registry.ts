// The rule registry: one array, in the order findings are attributed when two rules tie, plus the
// per-rule on/off the app's toggles (#25) read and write.
//
// Adding a rule is two lines — import it, append it to RULES. Keep the array grouped by tier and
// alphabetical inside a tier, so a merge between two wave-3 branches conflicts on one line instead
// of reordering the file.

import type { TropeRule } from "./types.js";
import { aiLeakageRule } from "./rules/ai-leakage.js";
import { claudeFictionFramesRule, claudeFictionGesturesRule } from "./rules/claude-fiction.js";
import { demoIntensifierRule } from "./rules/demo.js";
import { claudeTechnicalVocabularyRule } from "./rules/claude-lexicon.js";
import { claudeFigurativeSuffixesRule } from "./rules/claude-figurative.js";
import {
  boldFirstBulletRule,
  emDashDensityRule,
  listicleInTrenchCoatRule,
  unicodeDecorationRule,
} from "./rules/formatting.js";
import { claudeAssistantVoiceRule } from "./rules/claude-assistant-voice.js";
import { claudeDiscourseMarkersRule } from "./rules/claude-discourse-markers.js";
import { claudeStockFramesRule } from "./rules/claude-stock-frames.js";
import { corporateJargonRule } from "./rules/corporate-jargon.js";
import { excessVocabularyRule } from "./rules/excess-vocabulary.js";
import { soundsLikeClaudeRule } from "./rules/sounds-like-claude.js";
import {
  lexDelveFamilyRule,
  lexFalseSuspenseRule,
  lexFillerTransitionsRule,
  lexInventedConceptLabelsRule,
  lexMagicAdverbsRule,
  lexOrnateNounsRule,
  lexPedagogicalVoiceRule,
  lexSignpostsRule,
  lexStakesInflationRule,
  lexVagueAttributionRule,
} from "./rules/lexical.js";
import { colonRevealRule } from "./rules/colon-reveal.js";
import { contrastTailRule } from "./rules/contrast-tail.js";
import { mirroredClausesRule } from "./rules/mirrored-clauses.js";
import { reframeRule } from "./rules/reframe.js";
import { tricolonRule } from "./rules/tricolon.js";
import { tricolonSeriesRule } from "./rules/tricolon-series.js";
import { anaphoraRule } from "./rules/anaphora.js";
import { aphoristicEnderRule } from "./rules/aphoristic-ender.js";
import { deadMetaphorRule } from "./rules/dead-metaphor.js";
import { elegantVariationRule } from "./rules/elegant-variation.js";
import { dilutionRule, nearDuplicateRule } from "./rules/repetition.js";
import { selfPosedQuestionRule } from "./rules/self-posed-question.js";
import { falseRangeRule } from "./rules/false-range.js";
import { countdownRule, punchyFragmentsRule } from "./rules/fragments.js";
import { ingTackOnRule } from "./rules/ing-tackon.js";
import { setupTurnRule } from "./rules/setup-turn.js";
import { staccatoRegisterRule } from "./rules/staccato-register.js";
import { servesAsDodgeRule } from "./rules/serves-as.js";

export const RULES: readonly TropeRule[] = [
  // --- lexical ---
  aiLeakageRule, // claude-isms (#34) — assistant/tool boilerplate + leaked artifact strings
  claudeFictionFramesRule,
  claudeFictionGesturesRule,
  demoIntensifierRule, // DEMO — delete once the first real lexical rule lands (see rules/demo.ts)
  claudeAssistantVoiceRule,
  claudeDiscourseMarkersRule,
  claudeStockFramesRule,
  claudeFigurativeSuffixesRule,
  claudeTechnicalVocabularyRule,
  corporateJargonRule,
  excessVocabularyRule,
  lexDelveFamilyRule,
  lexFalseSuspenseRule,
  lexFillerTransitionsRule,
  lexInventedConceptLabelsRule,
  lexMagicAdverbsRule,
  lexOrnateNounsRule,
  lexPedagogicalVoiceRule,
  lexSignpostsRule,
  lexStakesInflationRule,
  lexVagueAttributionRule,
  // --- syntactic ---
  colonRevealRule, // claude-isms (#34) — the setup-label colon
  contrastTailRule, // claude-isms (#34) — the trailing ", not X" dismissal
  falseRangeRule,
  ingTackOnRule,
  mirroredClausesRule,
  reframeRule,
  selfPosedQuestionRule,
  servesAsDodgeRule,
  tricolonRule,
  tricolonSeriesRule, // #34 — the comma series the IR rule's Compound path never sees
  // --- formatting ---
  boldFirstBulletRule,
  emDashDensityRule,
  listicleInTrenchCoatRule,
  unicodeDecorationRule,
  // --- discourse ---
  anaphoraRule,
  aphoristicEnderRule,
  countdownRule,
  deadMetaphorRule,
  dilutionRule,
  elegantVariationRule,
  nearDuplicateRule,
  punchyFragmentsRule,
  setupTurnRule, // #34 — "3 rules. And none you set.": a frame that never becomes a claim
  soundsLikeClaudeRule, // claude-isms capstone (#34) — see rules/sounds-like-claude.ts
  staccatoRegisterRule, // #34 — the de-punctuated document: the scrub relocated the tells
];

// Two rules sharing an id would make findings indistinguishable and dedupe against each other.
// Checked at import time so a collision between wave-3 branches fails the first test that runs,
// naming the id, instead of quietly halving someone's findings.
export function assertUniqueRuleIds(rules: readonly TropeRule[] = RULES): void {
  const seen = new Set<string>();
  for (const r of rules) {
    if (seen.has(r.id)) throw new Error(`duplicate rule id: ${r.id}`);
    seen.add(r.id);
  }
}
assertUniqueRuleIds(RULES);

// Saved per-rule preferences, keyed by rule id. Absent means on: a rule added after the user's
// prefs were stored is enabled by default, and an id for a rule that no longer exists is ignored
// rather than throwing, so stale settings never break a run.
export type RuleToggles = Readonly<Record<string, boolean>>;

export const enabledRules = (toggles: RuleToggles = {}, rules: readonly TropeRule[] = RULES): TropeRule[] =>
  rules.filter((r) => toggles[r.id] !== false);

export const getRule = (id: string, rules: readonly TropeRule[] = RULES): TropeRule | undefined =>
  rules.find((r) => r.id === id);
