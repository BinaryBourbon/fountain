// Claude fiction gesture cluster (issue #34) — the small set of gesture/atmosphere verbs and
// adverbs that recur, together, in Claude's fiction voice: dialogue-tag verbs (murmured, glanced,
// tilted...), micro-gestures (blinked, nodded, clutched...) and a handful of atmosphere words that
// ride along with them (stillness, unhurried, faintly). Every single entry is an ordinary English
// word with plenty of innocent everyday uses — that's WHY this is its own lexicon rather than
// folded into claude-fiction-frames: the tell isn't any one of these words, it's several of them
// showing up on the same page. See rules/claude-lexicon.ts for the severity model this earns:
// "candidate" by default (visible but weakest), escalating only once density crosses the
// threshold — never suppressed to nothing, because issue #34 wants a single hit to stay visible.
//
// Sourced from the same two places as claude-fiction-frames.ts, informing rather than being
// vendored (see that file for the full attribution). Corroboration found for this cluster
// specifically: slop-forensics' data/slop_list_trigrams.json (MIT) has "leaned back chair", "voice
// trembling slightly", "said voice trembling" and "voice low rumble" — all built around entries
// kept here (leaned, trembling). antislop-sampler's slop_phrase_prob_adjustments.json (Apache-2.0)
// floor list (0.03125) has "thrummed", "chuckles darkly", "hesitantly" and "eyes never leaving",
// which are close kin to this cluster but were left OUT: they're rarer / more distinctive words
// than the ones kept, and this lexicon deliberately sticks to the common, low-signal-per-hit words
// that only become a tell in a cluster — see #34's brief for the exact word list.
//
// lemma:true is used only where the regular-inflection suffix matcher (lemmaMatches, in
// rules/lexical.ts) actually gets the inflected forms right: plain -s/-es and -ed/-ing with e-drop.
// Three of the given inflected forms are consonant-doubling irregulars that matcher can't
// derive from their base (grin -> grinned/grinning, not "grined"/"grining"; same for nod, hum), so
// those three are listed as the literal past-tense form instead of base+lemma:true — matching only
// the exact attested inflection rather than silently mis-deriving the rest of the paradigm.
//
// PRECISION CALL (documented per #34's brief): obsidian, sternum, forearm-adjacent nouns like
// stillness are atmosphere words with an entirely literal, non-fiction sense ("the obsidian rock
// formation", "sternum" in an anatomy text). They're kept in, not dropped, because at "candidate"
// severity a lone literal hit is the weakest, most easily-ignored signal the linter produces, and
// this cluster's whole design already treats a single hit as low-stakes evidence — see
// claude-fiction-gestures.test.ts's severity assertion for the literal-rock case, which pins that
// single hit at "candidate" rather than asserting it doesn't fire at all.
import type { Lexicon } from "./types.js";

export const claudeFictionGestures: Lexicon = {
  id: "claude-fiction-gestures",
  name: "Claude fiction gesture cluster",
  defaultSeverity: "candidate",
  densityThreshold: 5,
  entries: [
    { match: "flicker", lemma: true, note: "covers flicker/flickers/flickered/flickering" },
    { match: "lean", lemma: true, note: "covers lean/leans/leaned/leaning" },
    { match: "blink", lemma: true, note: "covers blink/blinks/blinked/blinking" },
    { match: "gesture", lemma: true, note: "covers gesture/gestures/gestured/gesturing" },
    { match: "grinned", note: "consonant-doubling irregular (grin -> grinned); literal form only, see header" },
    { match: "nodded", note: "consonant-doubling irregular (nod -> nodded); literal form only, see header" },
    { match: "hummed", note: "consonant-doubling irregular (hum -> hummed); literal form only, see header" },
    { match: "murmur", lemma: true, note: "covers murmur/murmurs/murmured/murmuring" },
    { match: "whisper", lemma: true, note: "covers whisper/whispers/whispered/whispering" },
    { match: "glance", lemma: true, note: "covers glance/glances/glanced/glancing" },
    { match: "mutter", lemma: true, note: "covers mutter/mutters/muttered/muttering" },
    { match: "tilt", lemma: true, note: "covers tilt/tilts/tilted/tilting" },
    { match: "flinch", lemma: true, note: "covers flinch/flinches/flinched/flinching" },
    { match: "tremble", lemma: true, note: "covers tremble/trembles/trembled/trembling" },
    { match: "clutch", lemma: true, note: "covers clutch/clutches/clutched/clutching" },
    { match: "hiss", lemma: true, note: "covers hiss/hisses/hissed/hissing" },
    { match: "breathe", lemma: true, note: "covers breathe/breathes/breathed/breathing" },
    { match: "sternum", note: "atmosphere noun; literal-anatomy sense possible — see PRECISION CALL above" },
    { match: "stillness" },
    { match: "unhurried" },
    { match: "obsidian", note: "atmosphere noun; literal-rock sense possible — see PRECISION CALL above" },
    { match: "impossibly" },
    { match: "faintly" },
    { match: "momentarily" },
  ],
};
