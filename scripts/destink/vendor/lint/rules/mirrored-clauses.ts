// MIRRORED CLAUSES (claude-isms tier, #34) — two adjacent clauses poured into the same mould with
// the content words swapped out:
//
//   "Products impress people; platforms empower them."
//   "Engineers write code. Managers write memos."
//
// Same skeleton on both sides, two contrasting plural nouns in the subject slot, both halves the
// same length. Read one and you have read the other; the second clause exists for the symmetry,
// not for anything it adds. Detected over the Clause IR rather than by string shape, because the
// string is the least stable part of it — the semicolon, the period and the dash are all the same
// pattern once the units are lowered.
//
// --- the pattern ---
// A pair of ADJACENT clauses (consecutive clauses of one lowered unit, or the last clause of one
// unit against the first clause of the next — unit boundaries are sentence boundaries and ";" /
// ":", so the semicolon form and the two-sentence form are one code path) where ALL of:
//
//   affirmative     neither clause is negated. reframe.ts (#14) owns denied-then-replaced pairs;
//                   requiring both sides affirmative is the seam between the two rules, and it is
//                   what keeps "Products are not tools. Platforms are worlds." out of here.
//   different heads the two subject heads differ. anaphora.ts owns same-subject repeats
//                   ("Platforms empower people. Platforms create worlds."); a shared subject head
//                   is that rule's signal, not this one's.
//   plural, bare    BOTH subject heads are plural, non-pronominal nouns — the products/platforms
//                   shape, two generic categories being set against each other. This is the single
//                   biggest precision lever in the file: ordinary narrative prose ("The dog chased
//                   the ball. A cat slept on the sill.") has singular subjects and never qualifies.
//   same skeleton   both TRANSITIVE (a directObject complement) or both COPULAR (isCopular — a
//                   be-form with a predicate noun/adjective). predicateNoun and predicateAdj are
//                   one bucket on purpose: the rule-based chunker cheerfully tags "engines" in
//                   "Products are engines" as a predicate adjective, and splitting the bucket would
//                   make the rule's answer depend on that coin flip.
//   swapped content the complement heads differ too. Same frame AND the same object is one sentence
//                   restated, which is repetition.ts's territory, not a mirror.
//   bare frame      no prepositional phrase, subordinate clause or participial phrase anywhere in
//                   either clause, and no indirect object. A mirror is a tight subject-verb-object
//                   (or subject-be-complement) frame; this is what keeps out the sentences the
//                   rule-based chunker parses into the same shape by accident, e.g. "Birds gathered
//                   near a feeder by the fence. Markets closed early ahead of the holiday weekend."
//                   — two directObject clauses by the IR's reckoning, with the PPs folded into the
//                   object and the indirect-object slot, and not a mirror by anyone's.
//   same weight     clause lengths (words walked out of the IR) within LENGTH_SLACK tokens. The
//                   trope is metrically matched; a long clause beside a short one is not a mirror
//                   however well its parts line up.
//
// --- what it deliberately does not catch ---
//   * intransitive mirrors — "Products scale linearly; platforms scale exponentially." A null
//     complement carries no skeleton to match on, so admitting it would fire on any two adjacent
//     plural-subject sentences of similar length ("Birds gathered near the feeder. Markets closed
//     early ahead of the holiday.") — which is prose, not a mirror. Known false negative, taken
//     on purpose.
//   * singular mirrors — "The product impresses; the platform empowers." Real, and out of reach
//     without knowing that "product" and "platform" are contrastable categories.
//   * mirrors spanning a clause that failed to lower. Nothing lowered means nothing to compare.
//   * the chained middle. A clause belongs to ONE mirror: three mirrored sentences in a row report
//     as one pair plus a leftover, not as two pairs sharing the middle clause. Without that, an
//     ordinary sentence sandwiched between two plural-subject sentences of the same shape would
//     pull both into overlapping findings and double the density count.
//
// This is the most precision-risky rule in the tier, so severity starts a notch lower than the
// others': one pair is a "candidate" (structurally narrowed, unconfirmable without semantics — the
// same honesty false-range.ts uses), two are "low", three or more "medium". A writer who does this
// three times in a piece is not varying sentence shape at all, which is the thing worth saying.

import type { Clause, Compound, Complement, Infinitive, Gerund, Modifier, Nominal, Predicate, Word } from "../../ir.js";
import { complementHead, isCopular, isNegated, subjectHead, subjectIsPronominal } from "../ir-query.js";
import { spanning } from "../span.js";
import type { DocAnalysis, Finding, Severity, Span, TropeRule } from "../types.js";

const RULE_ID = "claude/mirrored-clauses";

const LENGTH_SLACK = 2; // clause lengths may differ by at most this many words

// --- clause length -----------------------------------------------------------------------------
// Walked out of the IR rather than taken from the unit's word count, because an in-unit pair shares
// one unit and there would be nothing to compare. A verb head may itself be a phrase ("has been
// running"), so words are counted by splitting each Word's text.

const wordsIn = (w: Word): number => w.text.trim().split(/\s+/).filter(Boolean).length;

const sum = (ns: number[]): number => ns.reduce((a, b) => a + b, 0);

function modifierWords(m: Modifier): number {
  switch (m.kind) {
    case "word":
      return wordsIn(m.value);
    case "prep":
      return wordsIn(m.prep) + nominalWords(m.object);
    case "clause":
      return wordsIn(m.connector) + clauseWords(m.value);
    case "participle":
      return wordsIn(m.verb) + (m.object ? nominalWords(m.object) : 0) + sum(m.modifiers.map(modifierWords));
  }
}

function nominalWords(n: Nominal): number {
  return wordsIn(n.head) + sum(n.modifiers.map(modifierWords)) + (n.appositive ? wordsIn(n.appositive) : 0);
}

const nominalOrCompoundWords = (n: Nominal | Compound<Nominal>): number =>
  "items" in n ? wordsIn(n.conjunction) + sum(n.items.map(nominalWords)) : nominalWords(n);

const verbalWords = (v: { head: Word; modifiers: Modifier[]; indirectObject?: Nominal }): number =>
  wordsIn(v.head) + sum(v.modifiers.map(modifierWords)) + (v.indirectObject ? nominalWords(v.indirectObject) : 0);

const verbalOrInfinitiveWords = (v: Infinitive | Gerund): number =>
  wordsIn(v.verb) + (v.object ? nominalWords(v.object) : 0) + sum(v.modifiers.map(modifierWords));

function predicateWords(p: Predicate): number {
  if (!("items" in p)) return verbalWords(p);
  return wordsIn(p.conjunction) + sum(p.items.map((part) => verbalWords(part.verb) + (part.complement ? complementWords(part.complement) : 0)));
}

function complementWords(c: Complement): number {
  switch (c.kind) {
    case "predicateAdj":
      return "items" in c.value ? wordsIn(c.value.conjunction) + sum(c.value.items.map(wordsIn)) : wordsIn(c.value);
    case "predicateNoun":
      return nominalOrCompoundWords(c.value);
    case "directObject":
      if ("head" in c.value) return nominalWords(c.value);
      if ("items" in c.value) return nominalOrCompoundWords(c.value);
      if ("kind" in c.value) return verbalOrInfinitiveWords(c.value);
      return clauseWords(c.value);
    case "objectComplement":
      return nominalOrCompoundWords(c.object) + ("head" in c.oc ? nominalWords(c.oc) : wordsIn(c.oc));
  }
}

function subjectWords(s: Clause["subject"]): number {
  if ("head" in s) return nominalWords(s);
  if ("items" in s) return nominalOrCompoundWords(s);
  if ("kind" in s) return verbalOrInfinitiveWords(s);
  return clauseWords(s);
}

function clauseWords(c: Clause): number {
  return subjectWords(c.subject) + predicateWords(c.verb) + (c.complement ? complementWords(c.complement) : 0);
}

// --- subject shape -----------------------------------------------------------------------------

const PLURAL_TAGS = new Set(["NNS", "NNPS"]);
const NOUN_TAGS = new Set(["NN", "NNP", "NNS", "NNPS"]);

// Plural by the tag when the parse supplies one, by surface form when the tag is a singular noun
// tag the chunker guessed wrong (it routinely calls a capitalized sentence-initial "Products" an
// NNP). "-ss" endings are excluded so "business" / "process" are not read as plurals; a stray
// "-is" singular ("analysis") is a known, accepted miss of that heuristic.
function isPluralNoun(w: Word): boolean {
  if (w.pos && PLURAL_TAGS.has(w.pos)) return true;
  if (w.pos && !NOUN_TAGS.has(w.pos)) return false;
  const lc = w.text.toLowerCase();
  return lc.length >= 4 && /[^s]s$/.test(lc);
}

const contrastableSubject = (c: Clause): Word | null => {
  const head = subjectHead(c);
  if (!head || subjectIsPronominal(c) || !isPluralNoun(head)) return null;
  return head;
};

// --- skeleton ----------------------------------------------------------------------------------

type Skeleton = "transitive" | "copular";

function skeletonOf(c: Clause): Skeleton | null {
  if (isCopular(c)) return "copular";
  if (c.complement?.kind === "directObject") return "transitive";
  return null;
}

// --- bareness ------------------------------------------------------------------------------------
// The mirror is a tight frame: subject, verb, object, nothing hanging off any of them. Requiring
// that is what separates "Products impress people" from the sentence the chunker parses into the
// same SHAPE but that nobody would call mirrored — "Birds gathered near a feeder by the fence"
// lowers to a directObject too, with the PP folded into the object's modifiers and "near" parked in
// the indirect-object slot. Determiners and adjectives are fine; a prepositional phrase, a
// subordinate clause or a participial phrase anywhere in the frame is not.
const HEAVY = new Set<Modifier["kind"]>(["prep", "clause", "participle"]);
const isLight = (ms: readonly Modifier[]): boolean => !ms.some((m) => HEAVY.has(m.kind));

const bareNominal = (n: Nominal | Compound<Nominal>): boolean =>
  "items" in n ? n.items.every(bareNominal) : isLight(n.modifiers);

function bareFrame(c: Clause): boolean {
  if ("items" in c.verb) return false; // a compound predicate is not a frame you can mirror
  if (c.verb.indirectObject || !isLight(c.verb.modifiers)) return false;
  if ("head" in c.subject ? !isLight(c.subject.modifiers) : !("items" in c.subject && bareNominal(c.subject))) return false;
  const comp = c.complement;
  if (!comp) return false;
  if (comp.kind === "predicateAdj") return true; // a Word (or a compound of Words): nothing to hang off
  if (comp.kind === "predicateNoun") return bareNominal(comp.value);
  if (comp.kind !== "directObject") return false;
  if ("head" in comp.value) return isLight(comp.value.modifiers);
  return "items" in comp.value ? bareNominal(comp.value) : false;
}

const same = (a: Word, b: Word): boolean => a.text.toLowerCase() === b.text.toLowerCase();

type Pair = { span: Span; a: Word; b: Word; skeleton: Skeleton };

function mirroredPair(a: Clause, b: Clause, span: Span): Pair | null {
  if (isNegated(a) || isNegated(b)) return null; // reframe.ts owns the negated pairs
  const sa = contrastableSubject(a), sb = contrastableSubject(b);
  if (!sa || !sb || same(sa, sb)) return null; // anaphora.ts owns the same-subject repeats
  const ka = skeletonOf(a), kb = skeletonOf(b);
  if (!ka || ka !== kb) return null;
  if (!bareFrame(a) || !bareFrame(b)) return null;
  const ca = complementHead(a), cb = complementHead(b);
  if (!ca || !cb || same(ca, cb)) return null;
  if (Math.abs(clauseWords(a) - clauseWords(b)) > LENGTH_SLACK) return null;
  return { span, a: sa, b: sb, skeleton: ka };
}

// --- findings ----------------------------------------------------------------------------------

const severityFor = (count: number): Severity => (count >= 3 ? "medium" : count === 2 ? "low" : "candidate");

export const mirroredClausesRule: TropeRule = {
  id: RULE_ID,
  name: "Mirrored clauses (parallel frames, swapped content)",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    // Every clause of the document, flattened in order, each remembering the unit it came from.
    // Adjacency is then a single sweep, and "consecutive clauses of one unit" and "last clause of
    // one unit against the first of the next" stop being two code paths.
    const flat = doc.units.flatMap((unit) => (unit.clauses ?? []).map((clause) => ({ clause, unit })));

    const pairs: Pair[] = [];
    for (let i = 0; i + 1 < flat.length; ) {
      const [x, y] = [flat[i]!, flat[i + 1]!];
      const span = x.unit === y.unit ? x.unit.span : spanning([x.unit, y.unit]);
      const pair = mirroredPair(x.clause, y.clause, span);
      if (!pair) {
        i++;
        continue;
      }
      pairs.push(pair);
      i += 2; // a clause belongs to one mirror: a run of three mirrored sentences is one pair plus
      // a leftover, not two overlapping pairs chained through the middle clause.
    }

    const severity = severityFor(pairs.length);
    const density = pairs.length >= 2 ? ` You build ${pairs.length} of these in this piece — at that rate the symmetry is the only thing the reader hears.` : "";

    return pairs.map((p) => ({
      ruleId: RULE_ID,
      span: p.span,
      severity,
      message: `Mirrored clauses: “${p.a.text}” and “${p.b.text}” in the same ${p.skeleton === "copular" ? "copular" : "subject-verb-object"} frame`,
      explanation:
        `Both halves run the same grammar with the words swapped — “${p.a.text}” does one thing, “${p.b.text}” does its opposite, ` +
        `at matching length. The symmetry sounds like an insight, but the second half only restates the first from the other side; ` +
        `nothing in it had to be true. Keep the claim you can back up and write it once, then spend the saved clause on why it matters.` +
        density,
    }));
  },
};
