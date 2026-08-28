// Generic-LLM excess vocabulary (issue #34, consolidation pass) — ordinary-looking words that
// showed up disproportionately more often in text written with LLM assistance than in matched
// human baselines, per two independent word-frequency studies. Unlike the claude-* lexicons in
// this directory, this is NOT Claude-specific: both source studies measured GPT-family output
// (ChatGPT-era papers, bulk GPT completions), so this lexicon is wired through the STANDARD
// lexical-tier rule (rules/excess-vocabulary.ts's buildStandardLexiconRule, the same density
// STEP-DOWN semantics as rules/lexical.ts's buildLexiconRule — see that file for why this couldn't
// just be added to LEXICONS and picked up by lexical.ts directly).
//
// Sources (both fetched directly for this file; no bulk vendoring — see per-bucket notes below):
//   - Kobak, González-Márquez, Horváth & Lause (2025), "Delving into LLM-assisted writing in
//     biomedical publications through excess vocabulary", Science Advances 11(27). Data + code:
//     https://github.com/berenslab/llm-excess-vocab (MIT License, Copyright (c) 2024 Dmitry Kobak,
//     Rita González-Márquez). Word list: results/excess_words.csv — every word below tagged
//     type=="style" in that file (as opposed to type=="content", domain/topic words like
//     "coronavirus", or type=="other", database/citation artifacts — neither belongs in a prose
//     style lexicon). The CSV itself does not carry the paper's per-word excess-usage ratio as a
//     column; the medium/low/candidate buckets below encode the paper's published ratio bands by
//     hand (the specific >=8x word list is the paper's own highest-ratio set).
//   - Juzek & Ward (2025), "Why Does ChatGPT 'Delve' So Much? Exploring the Sources of Lexical
//     Overrepresentation in Large Language Models", COLING 2025, pp. 6397-6411
//     (https://aclanthology.org/2025.coling-main.426/). Code + data:
//     https://github.com/tjuzek/delve (CC0 1.0 Universal — LICENSE-DATA). Focal words: the target
//     word list in code/other_datasets/count_keywords.py, filtered down to the actual AI-tell
//     vocabulary (that file also counts ordinary high-frequency words like "the"/"data"/"patients"
//     as a frequency baseline — those are not trope words and are excluded here).
//
// --- severity bands (owner call on #34, mapped from the two studies' reported effect sizes) -----
//
//   medium (pinned, no density gating): the paper's own highest-overrepresentation band, reported
//     at roughly 8x or more the expected rate. A single occurrence is already the signal these
//     words were chosen for.
//   low (pinned, no density gating): a real but smaller excess-usage effect (roughly 3-8x),
//     covering most of the CSV's type=="style" rows plus the Juzek & Ward focal words not already
//     in the medium band. Ordinary words with legitimate everyday uses, so pinned at the tier's
//     softest non-candidate rung rather than escalating.
//   candidate (NOT pinned — rides the lexicon's defaultSeverity so the standard step-down applies):
//     a small set of very high-volume, very ordinary words the paper still measured as elevated.
//     Alone, one of these is barely worth mentioning (see CLAUDE.md: "a single pattern... might be
//     fine"); rules/excess-vocabulary.ts's density step-down is what actually enforces that — see
//     that file's header for the mechanism.
//
// --- DEDUP against every existing lexicon (this tier's whole point per #34's consolidation ask —
// verified by running the fixture battery's cross-rule check, not just by inspection) ------------
//
//   EXCLUDED, already covered by lex-delve-family (rules/lexical.ts): delve, delves, delved,
//   delving (that lexicon's "delve" entry is lemma:true and already matches all four surface
//   forms) — despite "delve"/"delves"/"delved"/"delving" being literally in the paper's own
//   >=8x example list, adding them here would fire the SAME word twice under two different rule
//   ids for no added signal. Also excluded for the same reason: streamline/streamlined/streamlines
//   /streamlining, harness/harnesses/harnessing, utilize/utilized/utilizes/utilizing, and
//   leverage/leverages/leveraging (delve-family's streamline/harness/utilize/leverage entries are
//   all lemma:true or already cover the relevant inflections).
//   EXCLUDED, already in claude-technical-vocabulary (rules/claude-lexicon.ts, ACTIVE rule):
//   meticulously (pinned "low" there) and seamless/seamlessly (pinned "low" there) — despite
//   "meticulously" being in the paper's own >=8x example list, it already has an active rule.
//   EXCLUDED, already in lex-filler-transitions (rules/lexical.ts, ACTIVE rule): notably (exact
//   word, no lemma, already fires at "medium" with no density gate there) — "notable" (the
//   adjective, a different surface token) is NOT excluded, since that lexicon only matches the
//   literal string "notably".
//   EXCLUDED, thematically owned by lex-superficial-ing-verbs (data exists in lexicons/
//   superficial-ing-verbs.ts for issue #18's future rule, even though that lexicon isn't wired to
//   an active TropeRule yet — see rules/lexical.ts's STRUCTURAL_LEXICON_IDS): highlighting
//   (highlight/lemma:true already claims this inflection) and contributing/shaping (contribute/
//   shape, both lemma:true, already claim theirs). Adding them here would be redundant the moment
//   #18 lands its rule, so they're left out now instead of landing pre-broken.
//   EXCLUDED, generic function/grammar words the source CSV includes as raw frequency deltas but
//   that carry no distinguishable trope signal on their own (across, between, however, into, like,
//   these, this, were, while, within, both, need, hold/holds, based, offer/offers/offering, role,
//   approach, analysis, research, complex, impact, statement, findings, techniques, strategies,
//   various, valuable, individuals, understanding, using, thereby, ultimately, subsequent,
//   primarily/primary, particularly, potentially/potential, precise, predominantly, presents,
//   providing, despite, during, amid/amidst, alongside, midst, consequently, inquiries,
//   limitations, necessity, outcomes, resulting, remains, seeks, serves/serving, spanning,
//   struggle, swift/swiftly, thorough, urging, varying, verifies, wandering, yielding, warranting,
//   postponed, overwhelmed, persist, assess*, capabilities, categoriz*, challenge*, combating,
//   complicat*, comprising, demonstrat*, dependab*, detailing, diminish*, displaying, disrupts,
//   distinct*, diverse, easing, effectively, emerged/emerges, employed/employing/employs) — a
//   curation call, not an omission; a linter that fires "medium" on the word "however" is not
//   useful. "remarkable" is ALSO excluded even though it is a genuine CSV style word: it collides
//   with an existing NEGATIVE fixture in formatting-em-dash-density.ts ("nothing else remarkable at
//   all here today"), which the cross-rule battery caught.
import type { Lexicon } from "./types.js";

export const excessVocabulary: Lexicon = {
  id: "excess-vocabulary",
  name: "Excess LLM vocabulary",
  defaultSeverity: "low",
  densityThreshold: 3,
  entries: [
    // --- medium: pinned, the paper's own >=8x band (minus the delve-family/claude-technical- ---
    // --- vocabulary overlaps documented above) -----------------------------------------------
    { match: "showcasing", severity: "medium" },
    { match: "underscores", severity: "medium" },
    { match: "underscoring", severity: "medium" },
    { match: "surpassing", severity: "medium" },
    { match: "commendable", severity: "medium" },

    // --- low: pinned, the paper's ~3-8x band plus Juzek & Ward's focal words -------------------
    { match: "advancement", severity: "low" },
    { match: "advancements", severity: "low" },
    { match: "aligns", severity: "low", note: "Juzek & Ward focal word" },
    { match: "avenue", severity: "low" },
    { match: "avenues", severity: "low" },
    { match: "bolster", severity: "low" },
    { match: "bolstered", severity: "low" },
    { match: "bolstering", severity: "low" },
    { match: "boasts", severity: "low", note: "Juzek & Ward focal word" },
    { match: "burgeoning", severity: "low" },
    { match: "comprehending", severity: "low", note: "Juzek & Ward focal word" },
    { match: "compelling", severity: "low" },
    { match: "crafted", severity: "low" },
    { match: "crafting", severity: "low" },
    { match: "culminating", severity: "low" },
    { match: "delineates", severity: "low" },
    { match: "discern", severity: "low" },
    { match: "discernible", severity: "low" },
    { match: "elucidate", severity: "low" },
    { match: "elucidates", severity: "low" },
    { match: "elucidating", severity: "low" },
    { match: "embracing", severity: "low" },
    { match: "emphasizing", severity: "low", note: "Juzek & Ward focal word" },
    { match: "emulating", severity: "low" },
    { match: "encapsulates", severity: "low" },
    { match: "encompass", severity: "low" },
    { match: "encompassing", severity: "low" },
    { match: "endeavors", severity: "low" },
    { match: "endeavours", severity: "low" },
    { match: "exceptional", severity: "low" },
    { match: "exceptionally", severity: "low" },
    { match: "foundational", severity: "low" },
    { match: "formidable", severity: "low" },
    { match: "garnered", severity: "low", note: "Juzek & Ward focal word" },
    { match: "garnering", severity: "low" },
    { match: "groundbreaking", severity: "low", note: "Juzek & Ward focal word" },
    { match: "grappling", severity: "low" },
    { match: "groundwork", severity: "low" },
    { match: "hinges", severity: "low" },
    { match: "illuminates", severity: "low" },
    { match: "illuminating", severity: "low" },
    { match: "imperative", severity: "low" },
    { match: "impressive", severity: "low" },
    { match: "innovative", severity: "low" },
    { match: "interconnectedness", severity: "low" },
    { match: "interplay", severity: "low" },
    { match: "intricate", severity: "low", note: "Juzek & Ward focal word" },
    { match: "intricacies", severity: "low", note: "Juzek & Ward focal word" },
    { match: "intricately", severity: "low" },
    { match: "invaluable", severity: "low" },
    { match: "juxtaposed", severity: "low" },
    { match: "multifaceted", severity: "low" },
    { match: "necessitate", severity: "low" },
    { match: "necessitating", severity: "low" },
    { match: "noteworthy", severity: "low" },
    { match: "nuanced", severity: "low" },
    { match: "nuances", severity: "low" },
    { match: "orchestrating", severity: "low" },
    { match: "paving", severity: "low" },
    { match: "pinpoint", severity: "low" },
    { match: "pinpointing", severity: "low" },
    { match: "pioneering", severity: "low" },
    { match: "pivotal", severity: "low" },
    { match: "poised", severity: "low" },
    { match: "propelling", severity: "low" },
    { match: "pronounced", severity: "low" },
    { match: "realm", severity: "low", note: "Juzek & Ward focal word" },
    { match: "realms", severity: "low" },
    { match: "renowned", severity: "low" },
    { match: "revolutionize", severity: "low" },
    { match: "revolutionizing", severity: "low" },
    { match: "scrutinize", severity: "low" },
    { match: "scrutinizing", severity: "low" },
    { match: "showcase", severity: "low" },
    { match: "showcased", severity: "low" },
    { match: "showcases", severity: "low", note: "Juzek & Ward focal word (as \"showcases\")" },
    { match: "spurred", severity: "low" },
    { match: "substantiated", severity: "low" },
    { match: "surmount", severity: "low" },
    { match: "surpass", severity: "low" },
    { match: "surpassed", severity: "low" },
    { match: "surpasses", severity: "low", note: "Juzek & Ward focal word" },
    { match: "transformative", severity: "low" },
    { match: "unparalleled", severity: "low" },
    { match: "unraveling", severity: "low" },
    { match: "underexplored", severity: "low" },
    { match: "underscore", severity: "low" },
    { match: "underscored", severity: "low" },
    { match: "unexplored", severity: "low" },
    { match: "uncharted", severity: "low" },
    { match: "unveil", severity: "low" },
    { match: "unveiling", severity: "low" },
    { match: "unveils", severity: "low" },
    { match: "unveiled", severity: "low" },
    { match: "unlock", severity: "low" },
    { match: "unlocking", severity: "low" },
    { match: "versatility", severity: "low" },

    // --- candidate: NOT pinned — rides defaultSeverity ("low"), so the standard step-down in ---
    // --- rules/excess-vocabulary.ts demotes a below-threshold hit to "candidate" (see header) ---
    { match: "notable" },
    { match: "comprehensive" },
    { match: "crucial" },
    { match: "insights" },
    { match: "enhancing" },
  ],
};
