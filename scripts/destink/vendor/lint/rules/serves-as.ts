// The "Serves As" Dodge (issue #18) — {serve as, stand as, mark, represent} standing in for a
// plain "is"/"are". The word list lives in src/lint/lexicons/serves-as-verbs.ts (imported below,
// never redefined here); this file supplies the STRUCTURE that tells a dodge from a literal use
// of the same verb — the thing a word list alone can't do ("the sign marks the trailhead" uses
// the exact same word as "the plaque marks a turning point").
//
// Two grammatically different frames share the one lexicon:
//
//   PHRASAL — "serve as" / "stand as". SERVE and STAND are intransitive on their own; the dodge's
//   target sits inside an "as X" prepositional phrase hanging off the VERB
//   (clause.verb.modifiers), not the clause's own complement — clause.complement stays null
//   ("The building serves" has no object of its own; "as a reminder" is a PP, not a direct
//   object). Confirming the frame means finding that "as" PP and checking its object is a PLAIN
//   nominal: "The waiter serves as many tables as he can" fails this because the trailing
//   "as he can" leaves its own comparative clause-modifier hanging off the object ("many tables"
//   modified by an "as"-connected clause) — that nested modifier is the structural tell that this
//   is the "as ... as" comparative, not "serve as NOUN", and isPlainNominal below rejects it.
//
//   BARE — "mark" / "represent". These ARE transitive main verbs; the target is the clause's own
//   complement (direct object or predicate noun), read via ir-query's complementHead. Structurally
//   "the sign marks the trailhead" and "the plaque marks a turning point" are IDENTICAL shapes —
//   telling literal from figurative needs semantics (is the complement abstract?) that this rule
//   deliberately does not attempt (lexicons/types.ts's own note calls this exact call a wave-2
//   design decision, not something POS/structure can resolve). So the bare frame is scored lower
//   than the phrasal one and only escalates with repetition — see SEVERITY TIERS below.
//
// SEVERITY TIERS. Both frames start from servesAsVerbs.defaultSeverity ("low") and shift by one
// step along candidate < low < medium < high:
//   - PHRASAL hits get defaultSeverity shifted UP one tier ("full severity", medium) unconditionally
//     — the literal word "as" plus a plain nominal complement is confirming structural evidence a
//     bare transitive verb doesn't have, so a single hit is already trustworthy.
//   - BARE hits get defaultSeverity shifted DOWN one tier ("candidate" — see the Severity type's
//     own doc comment: "structurally-narrowed suspects a rule can't confirm without semantics",
//     which is exactly this case) UNLESS the document repeats the bare pattern at least
//     servesAsVerbs.densityThreshold times, in which case they hold at the lexicon's own
//     defaultSeverity ("low") — repetition is the only corroboration a structural-only check can
//     use for mark/represent, mirroring rules/demo.ts's "count first, judge second".
//
// PARSER GAP — reported per #18's ground rules and since CLOSED in the engine (issue #33). The
// rule-based chunker used to drop "as X" entirely after serve/stand:
// parse("The building serves as a reminder of the city's heritage.") returned
// `(S (NP (DT The) (NN building)) (VP (VBZ serves)))`, so clause.verb.modifiers was always [] and
// the phrasal frame could only be tested against hand-built Clause fixtures. parse.ts now reads a
// subordinator with no clause after it as a preposition, so the "as" PP reaches the IR and this
// frame fires through readDocument — including the discriminator above, since the comparative's
// "as he can" attaches to the object. See serves-as.test.ts's end-to-end describe block.
// mark/represent were never affected: plain transitive objects parse fine (verified against
// readDocument — "represents a turning point" and "marks a turning point" both lower to an
// ordinary directObject complement, and passive voice, "is represented by ...", correctly leaves
// clause.complement null, which the bare frame's own transitive-frame requirement already handles
// without any special-casing).

import nlp from "compromise";
import type { Clause, Compound, Nominal, Verbal, Word } from "../../ir.js";
import type { DocAnalysis, Finding, Severity, TropeRule, UnitAnalysis } from "../types.js";
import { complementHead } from "../ir-query.js";
import { POS_GATE_PREFIX, servesAsVerbs } from "../lexicons/index.js";
import { spanning } from "../span.js";

// --- lemma ---
//
// The "small lemma helper" #18 asks for. compromise, forced to read a BARE word as a verb,
// mis-tags some past-participle-shaped forms as adjectives instead ("marked" alone stays
// "marked" — compromise's own lexicon outranks the forced tag). Wrapping the word in a minimal
// "it WORD that" frame gives it the syntactic context compromise's tagger actually listens to,
// which resolves every inflection this lexicon lists (verified by hand: serves/served/serving/
// serve -> serve; stands/stood -> stand; marks/marking/marked/mark -> mark; represents/
// representing/represented/represent -> represent). ing-tackon.ts carries its own copy of this
// same helper rather than importing it from here, so each rule file stays self-contained the way
// rules/demo.ts is.
function lemmaOf(word: string): string {
  const inf = nlp(`it ${word} that`).verbs().toInfinitive().text();
  const stripped = inf.replace(/^it\s+/i, "").replace(/\s+that$/i, "");
  return (stripped || word).toLowerCase();
}

const lastToken = (text: string): string => {
  const parts = text.trim().split(/\s+/);
  return (parts[parts.length - 1] ?? "").toLowerCase();
};

// Bails on a Compound predicate, same call ir-query's isCopular makes and for the same reason:
// a compound predicate's conjuncts each carry their own complement, so there is no single
// clause-level verb/complement pair to test. A caller wanting per-conjunct precision can walk
// clause.verb.items itself.
const asVerbal = (clause: Clause): Verbal | null => ("head" in clause.verb ? clause.verb : null);

// A nominal (or compound) counts as "plain" only when none of its items carries a comparative
// "as"-clause of its own — see the PHRASAL doc comment above for why that's the discriminator
// between "serve as NOUN" and "serve as ADJ as CLAUSE".
function isPlainNominal(n: Nominal | Compound<Nominal>): boolean {
  const items = "items" in n ? n.items : [n];
  return items.every((it) => !it.modifiers.some((m) => m.kind === "clause" && m.connector.text.toLowerCase() === "as"));
}

// The phrasal frame's evidence: a prep modifier headed by "as" on the VERB, with a plain nominal
// object. This is the only shape lowerPP/lowerPredicate can produce for "as X" hanging off a verb
// (see the PARSER GAP note above for why today's parser never actually produces it for serve/stand).
function asPhraseObject(verbal: Verbal): Nominal | null {
  for (const m of verbal.modifiers) {
    if (m.kind === "prep" && m.prep.text.toLowerCase() === "as" && isPlainNominal(m.object)) return m.object;
  }
  return null;
}

// The bare frame's evidence: the CLAUSE's own complement is a nominal (direct object or predicate
// noun) — not an infinitive, not a causative small clause, and not absent (passive voice, or an
// intransitive use, leaves this null and correctly excludes those cases with no extra code).
function nominalComplementHead(clause: Clause): Word | null {
  const c = clause.complement;
  if (!c || (c.kind !== "directObject" && c.kind !== "predicateNoun")) return null;
  if (!("head" in c.value) && !("items" in c.value)) return null; // Infinitive | Clause value — not a nominal
  return complementHead(clause);
}

const SEVERITY_ORDER: Severity[] = ["candidate", "low", "medium", "high"];
const shiftSeverity = (s: Severity, delta: number): Severity => {
  const i = SEVERITY_ORDER.indexOf(s);
  return SEVERITY_ORDER[Math.min(SEVERITY_ORDER.length - 1, Math.max(0, i + delta))]!;
};

type Frame = "phrasal" | "bare";
type Hit = { unit: UnitAnalysis; verbText: string; frame: Frame; note: string | undefined };

// Locates a Word's (possibly multi-word) surface text among the unit's word spans, so the
// finding's span slices cleanly from doc.text — the Clause IR carries no offsets of its own (see
// src/lint/types.ts). Degrades to the whole unit's span when the text can't be found, per #18's
// instruction (e.g. a hand-built fixture whose `words` don't happen to mirror the Clause text).
function locate(unit: UnitAnalysis, text: string) {
  const tokens = text.trim().split(/\s+/).map((t) => t.toLowerCase());
  for (let i = 0; i + tokens.length <= unit.words.length; i++) {
    const slice = unit.words.slice(i, i + tokens.length);
    if (slice.every((w, j) => w.text.toLowerCase() === tokens[j])) return spanning(slice);
  }
  return unit.span;
}

export const servesAsDodgeRule: TropeRule = {
  id: "serves-as-dodge",
  name: 'The "Serves As" Dodge',
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const hits: Hit[] = [];

    for (const unit of doc.units) {
      if (!unit.clauses) continue;
      for (const clause of unit.clauses) {
        const verbal = asVerbal(clause);
        if (!verbal) continue;
        const lemma = lemmaOf(lastToken(verbal.head.text));

        const phrasalEntry = servesAsVerbs.entries.find((e) => Array.isArray(e.match) && e.match[0] === lemma);
        if (phrasalEntry && asPhraseObject(verbal)) {
          hits.push({ unit, verbText: verbal.head.text, frame: "phrasal", note: phrasalEntry.note });
          continue;
        }

        const bareEntry = servesAsVerbs.entries.find((e) => typeof e.match === "string" && e.match === lemma);
        if (bareEntry) {
          if (bareEntry.posGate && verbal.head.pos && !verbal.head.pos.startsWith(POS_GATE_PREFIX[bareEntry.posGate])) continue;
          if (nominalComplementHead(clause)) hits.push({ unit, verbText: verbal.head.text, frame: "bare", note: undefined });
        }
      }
    }

    // Count first, judge second (rules/demo.ts's contract): the bare frame's confidence is a
    // document-wide density call, computed once over every bare hit before any Finding is built.
    const bareCount = hits.filter((h) => h.frame === "bare").length;
    const bareDense = bareCount >= (servesAsVerbs.densityThreshold ?? 1);
    const bareSeverity = shiftSeverity(servesAsVerbs.defaultSeverity, bareDense ? 0 : -1);
    const phrasalSeverity = shiftSeverity(servesAsVerbs.defaultSeverity, 1);

    return hits.map((h) => {
      const span = locate(h.unit, h.verbText);
      if (h.frame === "phrasal") {
        return {
          ruleId: "serves-as-dodge",
          span,
          severity: phrasalSeverity,
          message: `“${h.verbText} as” stands in for “is”`,
          explanation: `“X ${h.verbText} as Y” dodges the plain copula (“X is Y”) to sound more consequential${h.note ? ` (${h.note})` : ""}. Swap in “is”/“was” and read it back — if the sentence survives, you didn't need “${h.verbText} as”.`,
        };
      }
      return {
        ruleId: "serves-as-dodge",
        span,
        severity: bareSeverity,
        message: `“${h.verbText}” may be doing “is”'s job`,
        explanation: `“mark”/“represent” sometimes just replace “is” for gravitas (compare the literal “the sign marks the trailhead” with the figurative “the plaque marks a turning point” — same verb, same shape). This rule can't tell those apart from structure alone, so treat it as a prompt: does a plain “is”/“was” fit just as well here?`,
      };
    });
  },
};
