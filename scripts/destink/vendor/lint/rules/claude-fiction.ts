// The two claude-isms fiction-tier rules (issue #34), wired via claude-lexicon.ts's
// buildClaudeLexiconRule factory (single-hit-fires, escalation-only severity — see that file's
// header for the full model). Kept out of the shared LEXICONS barrel (lexicons/index.ts) and out
// of rules/lexical.ts's generic per-lexicon builder on purpose: that path downgrades sparse hits
// toward "candidate", which is the opposite of what #34 wants for a rule built on distinctive
// fiction-register phrases and a deliberately-common gesture-verb cluster.
//
// Explanations (free.ts hint voice: concrete, second person, no lecture) name the pattern and
// point at the fix without accusing the writer of anything — a finding is a claim about the
// PHRASE, never the author (see claude-lexicon.ts's file header, "non-goals").

import type { TropeRule } from "../types.js";
import { buildClaudeLexiconRule } from "./claude-lexicon.js";
import { claudeFictionFrames } from "../lexicons/claude-fiction-frames.js";
import { claudeFictionGestures } from "../lexicons/claude-fiction-gestures.js";

export const claudeFictionFramesRule: TropeRule = buildClaudeLexiconRule(
  claudeFictionFrames,
  `"Barely above a whisper," "something else entirely," "little did she know" — these are stock ` +
    `scene-beat frames that show up over and over in Claude's fiction output. One is already the ` +
    `tell; a reader who's seen a few AI stories will clock it immediately. Write the actual ` +
    `sensory detail or the specific beat instead of reaching for the ready-made frame.`,
);

export const claudeFictionGesturesRule: TropeRule = buildClaudeLexiconRule(
  claudeFictionGestures,
  `Flickered, leaned, blinked, murmured, tilted, trembling, faintly — ordinary words on their own. ` +
    `What gives Claude's fiction voice away is several of them landing on the same page: a ` +
    `dialogue tag here, a micro-gesture there, until every beat gets the same handful of moves. ` +
    `One is normal; if this fires more than once or twice in a scene, swap the repeats for an ` +
    `action specific to that character and that moment.`,
);
