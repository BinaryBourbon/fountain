// Claude's dev-prose idiolect (issue #34) — real engineering vocabulary that shows up so often in
// AI-written docs, PRs and READMEs that a single occurrence already reads as machine-flavored,
// regardless of who typed it. This is NOT the generic lexical tier's data shape reused as-is: it is
// consumed by rules/claude-lexicon.ts's buildClaudeLexiconRule (single-hit fires, density only
// ESCALATES — see that file's header), not rules/lexical.ts's buildLexiconRule (density
// STEPS DOWN a sparse hit). Deliberately NOT added to lexicons/index.ts's LEXICONS barrel: that
// array feeds lexical.ts's LEXICAL_RULES, which builds one step-down rule per entry and would both
// mis-score this lexicon's findings and break lexical.test.ts's hardcoded "exactly 10 rules" count.
//
// Severity tiers (owner call on #34, by how load-bearing/strong the phrase reads as a Claude tell):
//   - entries with their own `severity: "high"` are pinned there — the strongest tells, immune to
//     density in both directions, same convention as lex-delve-family's "delve".
//   - entries with no `severity` ride defaultSeverity ("medium") and ESCALATE to "high" once the
//     document's total hits from this lexicon reach densityThreshold (4) — see claude-lexicon.ts.
//   - entries with their own `severity: "low"` are pinned there — dev-vernacular overlap that still
//     fires on a single hit, but never escalates past low on its own density signal alone.
//
// "load-bearing" is deliberately ABSENT from this file. It needs a literal-sense gate (clean before
// a structural noun: "the load-bearing wall") that a plain word-list entry can't express — it lives
// in rules/claude-figurative.ts instead, alongside the other pattern-shaped Claude-isms.
//
// A handful of entries are marked "(figurative)" in their note: they have an innocent literal sense
// (a "guardrail" on a highway, "moving parts" in an engine) that this lexicon does not attempt to
// exclude, same accepted trade-off as lex-ornate-nouns' "landscape" — see lexicons/types.ts's
// matching-strategy note. Unlike "load-bearing", these don't get a custom gate: the literal reading
// is rare enough in ordinary prose that the false-positive rate is low, and this lexicon's lack of
// any density step-down means an occasional literal hit reads as low-stakes on its own.

import type { Lexicon } from "./types.js";

export const claudeTechnicalVocabulary: Lexicon = {
  id: "claude-technical-vocabulary",
  name: "Claude's dev-prose idiolect",
  defaultSeverity: "medium",
  densityThreshold: 4,
  entries: [
    // --- high: pinned, the strongest single-hit tells --------------------------------------
    { match: ["worth", "stating", "plainly"], severity: "high" },

    // --- medium: no severity override, rides defaultSeverity, escalates at density 4 -------
    { match: "battle-tested" },
    { match: "footgun" },
    { match: ["escape", "hatch"], note: "figurative — an actual physical escape hatch is rare in dev prose" },
    { match: ["happy", "path"] },
    { match: ["blast", "radius"], note: "figurative" },
    { match: ["table", "stakes"] },
    { match: ["north", "star"], note: "figurative" },
    { match: ["single", "source", "of", "truth"] },
    { match: ["paper", "cut"], note: "figurative" },
    { match: ["paper", "cuts"], note: "figurative" },
    { match: ["sharp", "edges"], note: "figurative" },
    { match: ["cognitive", "load"] },
    { match: ["mental", "model"] },
    { match: ["first-class", "citizen"] },
    { match: ["batteries", "included"] },

    // --- low: pinned, dev-vernacular overlap that still fires on a single hit --------------
    { match: "guardrails", severity: "low", note: "figurative" },
    { match: ["moving", "parts"], severity: "low", note: "figurative" },
    { match: "seamless", severity: "low" },
    { match: "seamlessly", severity: "low" },
    { match: "performant", severity: "low" },
    { match: "idiomatic", severity: "low" },
    { match: "opinionated", severity: "low" },
    { match: "principled", severity: "low" },
    { match: "pragmatic", severity: "low" },
    { match: "composable", severity: "low" },
    { match: "ergonomics", severity: "low" },
    { match: "ergonomic", severity: "low" },
    { match: "affordance", severity: "low" },
    { match: ["surface", "area"], severity: "low", note: "figurative" },
    { match: "future-proof", severity: "low" },
    { match: "non-trivial", severity: "low" },
    { match: "meticulously", severity: "low" },
    { match: "thoughtfully", severity: "low" },
    { match: "gracefully", severity: "low" },
    { match: "holistic", severity: "low" },
    { match: "orthogonal", severity: "low", note: "figurative" },
    { match: ["flesh", "out"], severity: "low" },
    { match: ["round", "out"], severity: "low" },
    { match: ["wire", "up"], severity: "low" },
    { match: ["thread", "through"], severity: "low" },
    { match: ["plumb", "through"], severity: "low" },
    { match: "spiritually", severity: "low" },
    { match: ["morally", "equivalent"], severity: "low" },
    { match: "modulo", severity: "low", note: "as \"except for\", not the arithmetic operator" },
  ],
};
