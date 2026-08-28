// Barrel for the lexical tier of the de-stink linter (issue #20). Wave-2 rules import LEXICONS
// (and the shape types) from here rather than reaching into individual files.
export type { PosGate, LexiconEntry, Lexicon } from "./types.js";
export { POS_GATE_PREFIX } from "./types.js";

import type { Lexicon } from "./types.js";
import { delveFamily } from "./delve-family.js";
import { ornateNouns } from "./ornate-nouns.js";
import { fillerTransitions } from "./filler-transitions.js";
import { falseSuspense } from "./false-suspense.js";
import { pedagogicalVoice } from "./pedagogical-voice.js";
import { signposts } from "./signposts.js";
import { stakesInflation } from "./stakes-inflation.js";
import { vagueAttribution } from "./vague-attribution.js";
import { inventedConceptLabels } from "./invented-concept-labels.js";
import { magicAdverbs } from "./magic-adverbs.js";
import { servesAsVerbs } from "./serves-as-verbs.js";
import { superficialIngVerbs } from "./superficial-ing-verbs.js";

export {
  delveFamily,
  ornateNouns,
  fillerTransitions,
  falseSuspense,
  pedagogicalVoice,
  signposts,
  stakesInflation,
  vagueAttribution,
  inventedConceptLabels,
  magicAdverbs,
  servesAsVerbs,
  superficialIngVerbs,
};

export const LEXICONS: readonly Lexicon[] = [
  delveFamily,
  ornateNouns,
  fillerTransitions,
  falseSuspense,
  pedagogicalVoice,
  signposts,
  stakesInflation,
  vagueAttribution,
  inventedConceptLabels,
  magicAdverbs,
  servesAsVerbs,
  superficialIngVerbs,
];
