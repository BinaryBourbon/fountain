// Rule-based constituency chunker. Tagged tokens -> PTB Tree, which the existing (tested)
// lower() turns into Clause IR. Deliberately a pragmatic subset for the pedagogical domain
// (simple-to-moderate sentences); it degrades gracefully and the UI catches hard failures.
//
// ENGLISH-SPECIFIC SEAM (1 of 2). This chunker hard-codes English word order (subject before
// verb, adjectives before the head noun). A future multilingual path does NOT extend this; it
// swaps in a Universal-Dependencies parser and a dependency->IR lowering. The IR is the
// convergence point — both paths feed the same Clause IR, layout, and renderer.
//
// Core idea: an NP's open-class run stops at the first verb-like word, so the boundary between
// subject and predicate falls out of greedy NP parsing rather than needing a separate step.

import type { Tree } from "../ptb.js";
import { tag, type Tagged } from "./tagger.js";
import { VERBS, isCapitalized, MODAL, COPULA, AUX } from "./lexicon.js";

const leaf = (label: string, word: string): Tree => ({ label, word, children: [] });
const node = (label: string, children: Tree[]): Tree => ({ label, children });

// Verb-like: compromise tagged it a verb (forced), OR the seed lexicon/morphology catches one
// compromise mis-tagged as a noun ("bark", "runs"). The lexicon can over-fire on noun uses
// ("a big old walk"); parseBaseNP guards that with a head-noun check, not this predicate.
const looksLikeVerb = (t: Tagged): boolean =>
  t.forced === "V" || (t.tag === "X" && (VERBS.has(t.lc) || t.lc.endsWith("ed") || t.lc.endsWith("ing")));

// Questions invert the auxiliary before the subject ("Can dogs bark?", "Why can X identify Y?").
// Rewrite to declarative order so the SVO grammar handles them: aux subj ... -> subj aux ...,
// routing the wh-word to its role (why/when/where/how -> adverb; who/what/which -> subject or
// the gapped object).
const WH_ADJUNCT = new Set(["why", "when", "where", "how"]);
const WH_ARG = new Set(["who", "whom", "what", "which"]);
const isAux = (t: Tagged) => t.tag === "MD" || t.tag === "AUX" || t.tag === "COP";

function normalizeQuestion(ts: Tagged[]): Tagged[] {
  if (ts.length === 0) return ts;
  // compromise sometimes noun-tags a capitalized sentence-initial aux ("Can ...", "Is ..."); fix it.
  const a0 = ts[0]!;
  if (a0.tag === "X") {
    if (MODAL.has(a0.lc)) a0.tag = "MD";
    else if (COPULA.has(a0.lc)) a0.tag = "COP";
    else if (AUX.has(a0.lc)) a0.tag = "AUX";
  }

  let wh: Tagged | null = null;
  let rest = ts;
  if (WH_ADJUNCT.has(ts[0]!.lc) || WH_ARG.has(ts[0]!.lc)) {
    wh = ts[0]!;
    rest = ts.slice(1);
  }

  if (rest.length > 0 && isAux(rest[0]!)) {
    const aux = rest[0]!;
    // minimal subject NP after the aux: determiner? + adjectives + head noun(s) — stop at the
    // predicate (an adjective AFTER the noun, e.g. "is the sky | blue", is NOT part of the subject)
    let k = 1;
    while (k < rest.length && (rest[k]!.tag === "DT" || rest[k]!.tag === "PRP$")) k++;
    if (k < rest.length && rest[k]!.tag === "PRP") k++;
    else {
      while (k < rest.length && (rest[k]!.tag === "JJ" || rest[k]!.tag === "RB")) k++; // pre-noun modifiers
      while (k < rest.length && (rest[k]!.tag === "X" || rest[k]!.tag === "CD") && !looksLikeVerb(rest[k]!)) k++; // noun(s)
    }
    let subj = rest.slice(1, k);
    // In a question the word right after the aux IS the subject, even if the tagger guessed a
    // verb for it ("Can dogs bark" — compromise tags "dogs" as a verb). Force it to a noun.
    if (subj.length === 0 && k < rest.length && (rest[k]!.tag === "X" || rest[k]!.tag === "JJ")) {
      subj = [{ word: rest[k]!.word, lc: rest[k]!.lc, tag: "X" }];
      k++;
    }
    if (subj.length > 0) {
      let out: Tagged[] = [...subj, aux, ...rest.slice(k)]; // un-invert: subject + aux + rest
      if (wh) out = [...out, { word: wh.word, lc: wh.lc, tag: WH_ARG.has(wh.lc) ? "X" : "RB" }]; // arg->object, adjunct->adverb
      return out;
    }
  }
  // no inversion: a wh-subject ("Who chased the cat") stays the subject
  if (wh && WH_ARG.has(wh.lc)) return [{ word: wh.word, lc: wh.lc, tag: "X" }, ...rest];
  return ts;
}

function finiteVerbTag(word: string): string {
  const lc = word.toLowerCase();
  const cop: Record<string, string> = { is: "VBZ", are: "VBP", am: "VBP", was: "VBD", were: "VBD", be: "VB", been: "VBN", being: "VBG" };
  const aux: Record<string, string> = { has: "VBZ", have: "VBP", had: "VBD", do: "VBP", does: "VBZ", did: "VBD" };
  return cop[lc] ?? aux[lc] ?? (lc.endsWith("ing") ? "VBG" : lc.endsWith("ed") ? "VBD" : lc.endsWith("s") ? "VBZ" : "VBP");
}

const nounTag = (word: string): string => (isCapitalized(word) ? "NNP" : word.toLowerCase().endsWith("s") ? "NNS" : "NN");

type R = { tree: Tree; next: number } | null;

// determiner/possessive? + (adverb|adjective)* + head noun, OR a bare pronoun.
function parseBaseNP(ts: Tagged[], i: number, end: number): R {
  const kids: Tree[] = [];
  let j = i;
  if (j < end && ts[j]!.tag === "DT") kids.push(leaf("DT", ts[j++]!.word));
  else if (j < end && ts[j]!.tag === "PRP$") kids.push(leaf("PRP$", ts[j++]!.word));

  if (j < end && ts[j]!.tag === "PRP") {
    kids.push(leaf("PRP", ts[j++]!.word));
    return { tree: node("NP", kids), next: j };
  }

  // open-class run: adjectives + head noun. A verb-like word ends the run ONLY once we already
  // have a head noun (then it's the predicate: "dogs | bark"). Before that, a verb-like word is
  // taken as the noun head, so a determiner-led NP gets its head ("a big old | walk").
  const run: Tagged[] = [];
  let hasNoun = false;
  while (j < end && (ts[j]!.tag === "X" || ts[j]!.tag === "JJ" || ts[j]!.tag === "CD" || ts[j]!.tag === "RB")) {
    if (looksLikeVerb(ts[j]!) && hasNoun) break;
    if (ts[j]!.tag === "X" || ts[j]!.tag === "CD") hasNoun = true;
    run.push(ts[j]!);
    j++;
  }
  if (run.length === 0 && kids.length === 0) return null;

  // last open-class word is the head noun; earlier ones are modifiers
  let headIdx = -1;
  for (let k = run.length - 1; k >= 0; k--) if (run[k]!.tag === "X" || run[k]!.tag === "CD") { headIdx = k; break; }
  if (headIdx === -1) headIdx = run.length - 1; // no clear noun (e.g. an -ly word) -> last token is head
  run.forEach((t, k) => {
    if (k === headIdx) kids.push(leaf(nounTag(t.word), t.word));
    else if (t.tag === "RB") kids.push(leaf("RB", t.word));
    else if (t.tag === "CD") kids.push(leaf("CD", t.word));
    else kids.push(leaf("JJ", t.word)); // pre-head open-class word -> adjective
  });
  if (headIdx === -1 && kids.length === 0) return null;
  return { tree: node("NP", kids), next: j };
}

// "SUB" is accepted alongside IN/TO because several subordinators double as prepositions ("as",
// "since", "after", "before", "until", "while"). Callers gate on the tag themselves; parseSingleVP
// is the one that reaches here with a SUB, and only after a clause reading has already failed.
function parsePP(ts: Tagged[], i: number, end: number): R {
  const t = ts[i]!.tag;
  if (t !== "IN" && t !== "TO" && t !== "SUB") return null;
  const np = parseNP(ts, i + 1, end);
  if (!np) return null;
  // Correlative comparative: "as many tables AS he can". The second "as" introduces a clause that
  // belongs to the OBJECT ("many tables"), not to the main verb — attaching it here is what keeps
  // "serves as many tables as he can" structurally distinct from "serves as a reminder".
  let obj = np.tree;
  let next = np.next;
  if (next < end && ts[next]!.tag === "SUB" && ts[next]!.lc === ts[i]!.lc) {
    const s = parseS(ts, next + 1, end);
    if (s) {
      obj = node("NP", [np.tree, node("SBAR", [leaf("IN", ts[next]!.word), s.tree])]);
      next = s.next;
    }
  }
  return { tree: node("PP", [leaf("IN", ts[i]!.word), obj]), next };
}

// Infinitive phrase: "to" + verb + (object) + (adverbs/PPs). A verbal — diagrammed on a stand.
function parseInfinitive(ts: Tagged[], i: number, end: number): R {
  const verb = ts[i + 1];
  if (!verb) return null;
  const kids: Tree[] = [leaf("TO", ts[i]!.word), leaf("VB", verb.word)];
  let j = i + 2;
  while (j < end && ts[j]!.tag !== "CC") {
    const t = ts[j]!;
    if (t.tag === "RB") {
      kids.push(node("ADVP", [leaf("RB", t.word)]));
      j++;
    } else if (t.tag === "IN" || t.tag === "TO") {
      const pp = parsePP(ts, j, end);
      if (!pp) break;
      kids.push(pp.tree);
      j = pp.next;
    } else if (t.tag === "DT" || t.tag === "PRP$" || t.tag === "PRP" || t.tag === "JJ" || (t.tag === "X" && !looksLikeVerb(t)) || t.tag === "CD") {
      const np = parseNP(ts, j, end);
      if (!np) break;
      kids.push(np.tree);
      j = np.next;
    } else break;
  }
  return { tree: node("INF", kids), next: j };
}

// base NP + trailing PPs + coordination (NP CC NP)
function parseNP(ts: Tagged[], i: number, end: number): R {
  const base = parseBaseNP(ts, i, end);
  if (!base) return null;
  let j = base.next;
  const post: Tree[] = [];
  while (j < end && ts[j]!.tag === "IN") {
    const pp = parsePP(ts, j, end);
    if (!pp) break;
    post.push(pp.tree);
    j = pp.next;
  }
  let tree = post.length ? node("NP", [base.tree, ...post]) : base.tree;

  if (j < end && ts[j]!.tag === "CC") {
    const rhs = parseNP(ts, j + 1, end);
    if (rhs) {
      tree = node("NP", [tree, leaf("CC", ts[j]!.word), rhs.tree]);
      j = rhs.next;
    }
  }
  return { tree, next: j };
}

// one predicate: verb chain + complement (object / predicate noun / adjective) + modifiers
function parseSingleVP(ts: Tagged[], i: number, end: number): R {
  const kids: Tree[] = [];
  let j = i;
  let isCop = false;
  const isAuxOrVerb = (t: Tagged) => t.tag === "MD" || t.tag === "AUX" || t.tag === "COP" || looksLikeVerb(t);
  while (j < end) {
    const t = ts[j]!;
    if (isSetOffParticiple(ts, j)) break; // "barked, wagging its tail" — not part of the verb chain
    if (isAuxOrVerb(t)) {
      if (t.tag === "COP") isCop = true;
      kids.push(leaf(t.tag === "MD" ? "MD" : finiteVerbTag(t.word), t.word));
      j++;
    } else if (t.tag === "RB" && j + 1 < end && isAuxOrVerb(ts[j + 1]!)) {
      kids.push(node("ADVP", [leaf("RB", t.word)])); // adverb inside the verb chain: "can not identify"
      j++;
    } else break;
  }
  if (kids.length === 0) return null;

  while (j < end && ts[j]!.tag !== "CC") {
    const t = ts[j]!;
    if (t.tag === "RB") {
      kids.push(node("ADVP", [leaf("RB", t.word)]));
      j++;
    } else if (t.tag === "TO" && j + 1 < end && looksLikeVerb(ts[j + 1]!)) {
      const inf = parseInfinitive(ts, j, end); // "to take a walk" — an infinitive object
      if (!inf) break;
      kids.push(inf.tree);
      j = inf.next;
    } else if (t.tag === "IN" || t.tag === "TO") {
      const pp = parsePP(ts, j, end); // "to" + noun is a preposition ("went to the store")
      if (!pp) break;
      kids.push(pp.tree);
      j = pp.next;
    } else if (t.tag === "SUB") {
      const s = parseS(ts, j + 1, end);
      if (s) {
        kids.push(node("SBAR", [leaf("IN", t.word), s.tree]));
        j = s.next;
      } else {
        // No clause after it, so the subordinator is being used as a PREPOSITION: "serves as a
        // reminder", "left after the movie". Without this fallback the whole phrase was dropped
        // on the floor (#33) — the VP ended at the verb and everything after it vanished.
        const pp = parsePP(ts, j, end);
        if (!pp) break;
        kids.push(pp.tree);
        j = pp.next;
      }
    } else if (isCop && (t.tag === "JJ" || t.tag === "X") && !looksLikeVerb(t)) {
      // predicate adjective(s): copula + bare adjective(s), incl. "tiny and loud"
      const adjLike = (x: Tagged) => (x.tag === "JJ" || x.tag === "X") && !looksLikeVerb(x);
      const adj: Tree[] = [];
      for (;;) {
        if (j < end && adjLike(ts[j]!)) adj.push(leaf("JJ", ts[j++]!.word));
        else if (j + 1 < end && ts[j]!.tag === "CC" && adjLike(ts[j + 1]!)) adj.push(leaf("CC", ts[j++]!.word));
        else break;
      }
      kids.push(node("ADJP", adj));
    } else if (t.tag === "DT" || t.tag === "PRP$" || t.tag === "PRP" || t.tag === "JJ" || (t.tag === "X" && !looksLikeVerb(t)) || t.tag === "CD") {
      const np = parseNP(ts, j, end);
      if (!np) break;
      kids.push(np.tree); // lower() decides object vs predicate-nominative by copula
      j = np.next;
    } else break;
  }
  return { tree: node("VP", kids), next: j };
}

// predicate with optional coordination (VP CC VP)
function parseVP(ts: Tagged[], i: number, end: number): R {
  const first = parseSingleVP(ts, i, end);
  if (!first) return null;
  let j = first.next;
  if (j < end && ts[j]!.tag === "CC") {
    const rhs = parseSingleVP(ts, j + 1, end);
    if (rhs) return { tree: node("VP", [first.tree, leaf("CC", ts[j]!.word), rhs.tree]), next: rhs.next };
  }
  return first;
}

// A participial phrase set off by a comma — "..., highlighting its importance". Both halves of the
// signal matter: an -ing verb, and a comma on the word before it (Tagged.comma). Everything the
// chunker used to do with such a phrase was drop it (#33) — parseSingleVP has no rule for a verb
// after a complete predicate, so it broke out and the rest of the sentence vanished.
//
// The comma requirement is what keeps this from mis-attaching: "I saw the man running" has no
// comma, so it keeps today's behavior rather than gaining a participle on the wrong noun.
// Restricted to -ing too — a bare -ed/-en in the same slot is more often a mis-tagged main verb.
const isSetOffParticiple = (ts: Tagged[], j: number): boolean => {
  const t = ts[j]!;
  return !!ts[j - 1]?.comma && looksLikeVerb(t) && t.lc.endsWith("ing") && t.tag !== "COP" && t.tag !== "AUX";
};

// (S (VP (VBG highlighting) (NP its importance) ...)) — wrapped in its own S because that is the
// shape lower.ts recognizes as a participial phrase (isParticipial: an S with no subject NP whose
// VP is VBG/VBN-headed), which it then attaches to the subject noun as a { kind: "participle" }
// modifier — where Reed-Kellogg puts a participle.
function parseParticipial(ts: Tagged[], i: number, end: number): R {
  const kids: Tree[] = [leaf("VBG", ts[i]!.word)];
  let j = i + 1;
  while (j < end && ts[j]!.tag !== "CC") {
    const t = ts[j]!;
    if (t.tag === "RB") {
      kids.push(node("ADVP", [leaf("RB", t.word)]));
      j++;
    } else if (t.tag === "IN" || t.tag === "TO") {
      const pp = parsePP(ts, j, end);
      if (!pp) break;
      kids.push(pp.tree);
      j = pp.next;
    } else if (t.tag === "DT" || t.tag === "PRP$" || t.tag === "PRP" || t.tag === "JJ" || t.tag === "CD" || (t.tag === "X" && !looksLikeVerb(t))) {
      const np = parseNP(ts, j, end);
      if (!np) break;
      kids.push(np.tree);
      j = np.next;
    } else break;
  }
  return { tree: node("S", [node("VP", kids)]), next: j };
}

// Consume a run of comma-set-off participial phrases starting at `j`.
function parseParticipials(ts: Tagged[], j: number, end: number, into: Tree[]): number {
  while (j < end && isSetOffParticiple(ts, j)) {
    const p = parseParticipial(ts, j, end);
    if (!p || p.next === j) break;
    into.push(p.tree);
    j = p.next;
  }
  return j;
}

function parseS(ts: Tagged[], i: number, end: number): R {
  const subj = parseNP(ts, i, end);
  if (!subj) return null;
  // A participial phrase can sit between the subject and the predicate ("The dog, barking
  // furiously, chased the cat") or trail the whole clause ("... opened in 1994, highlighting its
  // importance"). Both end up as S siblings, which lower.ts hangs on the subject noun.
  const parts: Tree[] = [];
  const afterMid = parseParticipials(ts, subj.next, end, parts);
  let vp = parseVP(ts, afterMid, end);
  if (!vp && afterMid !== subj.next) {
    parts.length = 0; // no predicate after the participle — fall back to reading it as the verb
    vp = parseVP(ts, subj.next, end);
  }
  if (!vp) return null;
  const j = parseParticipials(ts, vp.next, end, parts);
  return { tree: node("S", [subj.tree, vp.tree, ...parts]), next: j };
}

// Parse into a constituency Tree. A single clause returns its S; independent clauses joined by
// a conjunction ("Birds sing and dogs bark") return an S whose children are several S + CC
// (a compound sentence). Throws if it can't find even one clause.
export function parse(text: string): Tree {
  // Punctuation tokens are dropped, but a comma's POSITION is kept on the word it follows — the
  // tagger already records it that way (Tagged.comma), and a standalone comma token (spaced input,
  // "a , b") has to fold into the same place so both spellings parse alike.
  const kept: Tagged[] = [];
  for (const t of tag(text)) {
    if (t.tag === ".") continue;
    if (t.tag === ",") {
      const last = kept[kept.length - 1];
      if (last) last.comma = true;
      continue;
    }
    kept.push(t);
  }
  const ts = normalizeQuestion(kept);

  const clauses: Tree[] = [];
  const ccs: string[] = [];
  let i = 0;
  while (i < ts.length) {
    const s = parseS(ts, i, ts.length);
    if (!s) break;
    clauses.push(s.tree);
    i = s.next;
    if (i < ts.length && ts[i]!.tag === "CC") {
      ccs.push(ts[i]!.word);
      i++;
    } else break;
  }
  if (clauses.length === 0) throw new Error("couldn't parse: expected a subject and a verb");
  if (clauses.length === 1) return clauses[0]!;

  const kids: Tree[] = [];
  clauses.forEach((c, k) => {
    kids.push(c);
    if (k < ccs.length) kids.push(leaf("CC", ccs[k]!));
  });
  return node("S", kids);
}
