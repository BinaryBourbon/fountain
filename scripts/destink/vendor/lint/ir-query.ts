// Structural query helpers over the Clause IR (#10). The reframe rules (#11) need to ask
// questions the IR almost answers already — is this clause copular, is it negated, what's the
// complement head, what's the subject head — without re-deriving them from the parse tree each
// time. Pure functions over Clause; no layout, no parsing, no knowledge of source spans (that
// lives in DocAnalysis, see ./types.ts).

import type { Clause, Compound, Nominal, Predicate, Subject, Verbal, Word } from "../ir.js";

// --- copula ---

// Strict be-forms only ("is", "are", "was", "were", "am", "be", "been", "being"). seem/become/
// feel/look/appear/remain are copula-LIKE (linking verbs) but deliberately excluded: the issue
// scopes isCopular to be-forms, and folding in the wider linking-verb set would make the
// predicate's meaning caller-dependent. A rule that wants the wider set can test
// `clause.verb.head.text` itself against its own list; leaving this narrow keeps isCopular's
// contract unambiguous.
const BE_FORMS = new Set(["be", "am", "is", "are", "was", "were", "been", "being"]);

const lastWord = (text: string): string => {
  const parts = text.trim().split(/\s+/);
  return (parts[parts.length - 1] ?? "").toLowerCase();
};

// "isn't" / "wasn't" / "aren't" / "weren't": the rule-based tagger (src/nlp/tagger.ts) folds the
// negative contraction into the verb token itself rather than splitting it into its own word (see
// isNegated below for why), so the be-form check has to look past a trailing "n't" too. Modal
// contractions ("won't", "can't") strip to a non-be-form stem and correctly stay unmatched.
const stripContractedNegation = (word: string): string => (/n't$/i.test(word) ? word.slice(0, -3) : word);

/**
 * Is this clause copular — a be-form verb linking the subject to a predicate noun/adjective?
 *
 * The verb head is checked by its LAST word, so a verb-phrase head ("has been", "will be")
 * counts when the auxiliary chain actually ends in a be-form (predicating the complement), but
 * "has been running" does not (the head ends in "running", a participle, not a copula).
 *
 * Compound predicates ("has black fur and can jump high") are NOT inspected per-conjunct: each
 * conjunct's complement lives on its own PredicatePart (see PredicatePart in ../ir.ts), not on
 * Clause.complement, so there is no single clause-level complement to test against here.
 * isCopular bails to `false` for those rather than guessing which conjunct the caller means — a
 * rule that needs per-conjunct copularity can walk `clause.verb.items` itself.
 */
export function isCopular(clause: Clause): boolean {
  if (!("head" in clause.verb)) return false; // Compound predicate — see doc comment
  const last = lastWord(clause.verb.head.text);
  if (!BE_FORMS.has(last) && !BE_FORMS.has(stripContractedNegation(last))) return false;
  return clause.complement?.kind === "predicateNoun" || clause.complement?.kind === "predicateAdj";
}

// --- negation ---

// Per the original issue: "not" / "n't" only. #34 (the temporal-absolute reframe, "It was never X.
// It was always Y.") widens this to "never" too — "never" is a denial exactly the way "not" is,
// just placed in time rather than in the moment, and the reframe rule needs isNegated(a) to see it
// so the ordinary "copular, negated, then copular, affirmative, coreferent" pair check picks up the
// never/always shape for free, with no new predicate of its own. "always" stays OUT of this set: it
// marks the affirmative side, not a negation, and isNegated(b) must stay false there for the pair to
// register as a denial-then-replacement at all. A rule wanting to tell "never" apart from "not" (the
// reframe rule does, for its severity bonus) reads hasAbsoluteAdverb below instead of guessing from
// this set.
const NEGATORS = new Set(["not", "n't", "never"]);

const verbalHeads = (verb: Predicate): Verbal[] => ("items" in verb ? verb.items.map((p) => p.verb) : [verb]);

const hasNegationModifier = (verbal: Verbal): boolean =>
  verbal.modifiers.some((m) => m.kind === "word" && NEGATORS.has(m.value.text.toLowerCase()));

// A verb head can carry the negation fused into its own text ("isn't", "doesn't run") instead of
// as a separate modifier: compromise (the tagger's POS backend) splits "isn't" into an "isn't"
// term plus a SEPARATE zero-width term tagged Negative, and the tagger drops empty-text terms —
// so the rule-based chunker (src/nlp/tagger.ts + parse.ts) never sees "n't" as its own token for
// a contraction, and it ends up baked into the verb head instead (see lower.ts's verbHead, which
// joins multi-word verb chains with spaces). A tree from a different source (e.g. a gold PTB
// parse using the standard "is n't" leaf split) hits the modifier path above instead; this
// handles both shapes.
const headHasContractedNegation = (head: Word): boolean => head.text.split(/\s+/).some((tok) => /n't$/i.test(tok));

/**
 * Is this clause negated — a "not"/"n't"/"never" on the verb, spelled out or contracted?
 *
 * "never" is always its own "word" modifier in the rule-based tagger's output (unlike "n't", it
 * never fuses into the verb head's text — there is no "wasnever" to strip), so only the modifier
 * path in hasNegationModifier ever catches it; headHasContractedNegation stays "n't"-only.
 *
 * Unlike isCopular, this DOES look across every conjunct of a compound predicate: negation is a
 * per-Verbal fact (modifiers live on each PredicatePart's own verb), so `true` here means at
 * least one conjunct is negated. A rule wanting per-conjunct precision can inspect
 * `clause.verb.items[i].verb` directly.
 */
export function isNegated(clause: Clause): boolean {
  return verbalHeads(clause.verb).some((v) => hasNegationModifier(v) || headHasContractedNegation(v.head));
}

// --- absolute adverbs ("never" / "always") ---

// The bare word list "never"/"always" checks against, kept separate from NEGATORS above (isNegated
// only ever wants the negative half of this pair).
const ABSOLUTE_ADVERBS = new Set(["never", "always"]);

/**
 * Does the clause's verb carry "never" or "always" as a bare adverb modifier — the temporal-absolute
 * pair the reframe rule's never/always variant looks for (#34)? Returns whichever one is present, or
 * null for neither. Only ever one of the two can be true of a given clause in practice (a verb
 * doesn't carry both), so the first hit found across compound-predicate conjuncts is returned.
 *
 * Deliberately narrower than isNegated: this does not also catch "not" (that's what isNegated is
 * for), and it does not look past a fused verb head — the rule-based tagger never fuses "never" or
 * "always" into the verb the way it fuses "n't", so there is no equivalent fused-head shape to check.
 */
export function hasAbsoluteAdverb(clause: Clause): "never" | "always" | null {
  for (const v of verbalHeads(clause.verb)) {
    for (const m of v.modifiers) {
      if (m.kind === "word") {
        const w = m.value.text.toLowerCase();
        if (ABSOLUTE_ADVERBS.has(w)) return w as "never" | "always";
      }
    }
  }
  return null;
}

// --- heads ---

// A compound's head-of-record is its first item; see the plural `*Heads` variants below for all
// conjuncts. This mirrors lower.ts's own convention of treating the first/last item as
// significant (e.g. ditransitive resolution) rather than inventing a new rule here.
const firstOf = <T>(items: T[]): T | undefined => items[0];

const nominalOrCompoundHead = (n: Nominal | Compound<Nominal>): Word | null => ("head" in n ? n.head : (firstOf(n.items)?.head ?? null));
const wordOrCompoundHead = (v: Word | Compound<Word>): Word | null => ("items" in v ? (firstOf(v.items) ?? null) : v);

/**
 * The head word of a clause's complement, descending through Compound (first conjunct) and
 * through the verbal/clausal complement shapes:
 *  - predicateNoun / predicateAdj: the noun/adjective head itself.
 *  - directObject: the object's head; for an infinitive object ("wanted to leave"), the
 *    infinitive's own verb stands in as its head (there's no noun to point to).
 *  - directObject holding a full Clause (a causative small clause, "made her students read four
 *    novels"): no single head word describes that — returns null; a caller wanting more should
 *    read `clause.complement.value` directly.
 *  - objectComplement ("elected my uncle mayor"): the complement noun/adjective (the `oc`), not
 *    the object it's predicated of — that's what a caller means by "the complement" here.
 */
export function complementHead(clause: Clause): Word | null {
  const c = clause.complement;
  if (!c) return null;
  switch (c.kind) {
    case "predicateAdj":
      return wordOrCompoundHead(c.value);
    case "predicateNoun":
      return nominalOrCompoundHead(c.value);
    case "directObject":
      if ("head" in c.value) return c.value.head; // Nominal
      if ("items" in c.value) return nominalOrCompoundHead(c.value); // Compound<Nominal>
      if ("kind" in c.value) return c.value.verb; // Infinitive: its own verb stands in as the head
      return null; // Clause complement — see doc comment
    case "objectComplement":
      return c.ocIsAdj ? (c.oc as Word) : nominalOrCompoundHead(c.oc as Nominal);
  }
}

/** Every complement head, for a Compound predicateNoun/predicateAdj ("tiny and loud"). */
export function complementHeads(clause: Clause): Word[] {
  const c = clause.complement;
  if (!c) return [];
  if (c.kind === "predicateAdj") return "items" in c.value ? c.value.items : [c.value];
  if (c.kind === "predicateNoun") return "items" in c.value ? c.value.items.map((i) => i.head) : [c.value.head];
  const head = complementHead(clause);
  return head ? [head] : [];
}

const subjectHeadOf = (s: Subject): Word | null => {
  if ("head" in s) return s.head; // Nominal
  if ("items" in s) return firstOf(s.items)?.head ?? null; // Compound<Nominal>
  if ("kind" in s) return s.verb; // Infinitive | Gerund: its own verb is the head
  return null; // a noun clause used as subject ("Whoever made this...") has no single head word —
  // see doc comment on subjectHead.
};

/**
 * The head word of a clause's subject, descending through Compound (first conjunct — see
 * subjectHeads for all). A gerund/infinitive subject ("Running marathons is fun") uses its own
 * verb as the head, mirroring complementHead's treatment of a verbal complement. A full clause
 * used nominally as the subject ("Whoever made this pottery did a good job") has no single head
 * word — this returns null; a caller wanting the embedded subject can read
 * `(clause.subject as Clause).subject` (or recurse: `subjectHead(clause.subject as Clause)`).
 */
export function subjectHead(clause: Clause): Word | null {
  return subjectHeadOf(clause.subject);
}

/** Every subject head, for a Compound subject ("Both Max and I"). */
export function subjectHeads(clause: Clause): Word[] {
  const s = clause.subject;
  if ("items" in s) return s.items.map((i) => i.head);
  const head = subjectHeadOf(s);
  return head ? [head] : [];
}

// --- pronominal subject ---

// Kept local rather than importing src/nlp/lexicon.ts's PRON: this module works from the Clause
// IR alone (the lint layer's contract, see ./types.ts), without a dependency on the English
// parser seam. The lists deliberately overlap — both describe the same closed class of English
// function words — but lint's copy is free to grow independently of the parser's.
const PRONOUNS = new Set(["i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them"]);
const DEMONSTRATIVES = new Set(["this", "that", "these", "those"]);

/**
 * Is the clause's subject a bare pronoun or demonstrative ("It", "This", "They") rather than a
 * full noun phrase? Used by rules like the negative-parallelism reframe, where "This is not
 * bold" (demonstrative subject, thin referent) reads differently from "The building is not
 * bold" (concrete subject).
 *
 * Prefers the POS tag (PRP for personal pronouns) when the parse supplied one; falls back to a
 * word-list check when it didn't. The fallback matters in practice: the rule-based chunker's
 * lowering (lowerNP in ../lower.ts) leaves the head Word's `pos` unset when a bare NP has no
 * noun to serve as head (e.g. "This" alone, with nothing else in its NP) — the DT tag lands on a
 * *modifier* copy of the same word, not on the head we return here.
 */
export function subjectIsPronominal(clause: Clause): boolean {
  const head = subjectHead(clause);
  if (!head) return false;
  const lc = head.text.toLowerCase();
  if (head.pos === "PRP") return true;
  if (head.pos === "DT") return DEMONSTRATIVES.has(lc);
  if (head.pos) return false; // some other, non-pronominal tag (NN, NNP, ...): trust it over the word list
  return PRONOUNS.has(lc) || DEMONSTRATIVES.has(lc); // no POS tag at all: word-list fallback
}
