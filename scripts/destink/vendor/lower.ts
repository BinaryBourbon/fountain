// Lowering: constituency parse (Penn-Treebank Tree) -> Clause IR. THE BRIDGE — the piece no
// existing tool provides (see RESEARCH.md). Grammar-directed: it reads phrase structure to
// recover subject / predicate / complement, modifiers, PPs, coordination, and subordinate
// clauses. Deliberately a pragmatic subset; unsupported shapes throw a clear error so callers
// (e.g. lowerNBest) can fall back rather than silently mis-diagram.
//
// ENGLISH-SPECIFIC SEAM (2 of 2). Constituency-shaped and English-tuned (subject = first NP,
// copula list, PTB labels). A future multilingual path adds a SIBLING `dependency -> IR`
// lowering (UD arcs -> subject/object/modifiers); both produce the same Clause IR. Keeping
// the IR the convergence point is what keeps that door open.

import type { Clause, Nominal, Verbal, Modifier, Word, Compound, Complement, Sentence, Infinitive, Gerund, Subject, Predicate, PredicatePart } from "./ir.js";
import { parseBracket, phrase, type Tree } from "./ptb.js";

const w = (text: string): Word => ({ text });
const wt = (leaf: Tree): Word => ({ text: leaf.word!, pos: leaf.label }); // a Word from a single leaf, carrying its POS tag

const COPULA = new Set([
  "be", "am", "is", "are", "was", "were", "been", "being",
  "seem", "seems", "seemed", "become", "becomes", "became",
  "feel", "feels", "felt", "look", "looks", "appear", "appears", "remain", "remains",
]);

// Correlative pre-markers: "both ... and", "either ... or", "neither ... nor". The leading word
// is folded into the conjunction label rather than mis-read as a determiner on the first item.
const CORREL = new Set(["both", "either", "neither"]);
const isCorrelative = (t: Tree | undefined): boolean => !!t?.word && CORREL.has(t.word.toLowerCase());
const conjLabel = (correlative: string | null, conj: string): string => (correlative ? `${correlative}...${conj}` : conj);

const NOUN = new Set(["NN", "NNS", "NNP", "NNPS", "PRP"]);
const PREMOD = new Set(["DT", "JJ", "JJR", "JJS", "PRP$", "CD", "POS", "PDT", "RB", "VBN", "VBG"]); // RB: "very"; VBN/VBG: "burned toast"
const isVerb = (label: string) => /^(VB|MD|AUX)/.test(label);
const isCC = (t: Tree) => t.label === "CC";
const isPunct = (t: Tree) => /^[,:.]$/.test(t.label);

// Flatten a compound to a single Nominal where the IR needs one (prep objects, etc.).
const asNominal = (n: Nominal | Compound<Nominal>): Nominal =>
  "items" in n ? { head: w(n.items.map((i) => i.head.text).join(` ${n.conjunction.text} `)), modifiers: [] } : n;

// --- noun phrases ---

function lowerNP(np: Tree): Nominal | Compound<Nominal> {
  if (np.children.some(isCC)) return lowerCoordNP(np);

  // (NP (NP ...) (PP|SBAR|VP ...)+) — a base nominal with trailing post-modifiers, where a VP is a
  // reduced participial clause ("the girl running across the field").
  const first = np.children[0];
  const rest = np.children.slice(1);
  if (first && first.label === "NP" && rest.length > 0 && rest.every((c) => c.label === "PP" || c.label === "SBAR" || (c.label === "VP" && isParticipial(c)))) {
    const base = asNominal(lowerNP(first));
    for (const c of rest) base.modifiers.push(c.label === "PP" ? lowerPP(c) : c.label === "SBAR" ? lowerSBAR(c) : lowerParticipleVP(c));
    return base;
  }

  // flat NP: pre-modifiers, head noun (last noun wins; earlier nouns become noun-adjunct mods)
  const modifiers: Modifier[] = [];
  let headLeaf: Tree | null = null;
  let appositive: string | undefined;
  for (const c of np.children) {
    if (c.word !== undefined) {
      if (NOUN.has(c.label)) {
        if (headLeaf !== null) modifiers.push({ kind: "word", value: wt(headLeaf) });
        headLeaf = c;
      } else if (PREMOD.has(c.label)) {
        modifiers.push({ kind: "word", value: wt(c) });
      }
    } else if (c.label === "PP") modifiers.push(lowerPP(c));
    else if (c.label === "SBAR") modifiers.push(lowerSBAR(c));
    else if (c.label === "ADJP" || c.label === "QP") modifiers.push({ kind: "word", value: w(phrase(c)) }); // QP: "almost any"
    else if (c.label === "NP" && c.children.some((k) => k.label === "POS")) {
      // possessive noun ("Alicia's hobby"): the whole 's-phrase is a determiner-like slant modifier
      modifiers.push({ kind: "word", value: w(phrase(c).replace(/ (['’]s?)\b/g, "$1")) });
    } else if (c.label === "NP") appositive = phrase(c); // trailing name ("the hero Beowulf")
  }
  return { head: headLeaf ? wt(headLeaf) : w(phrase(np)), modifiers, ...(appositive ? { appositive: w(appositive) } : {}) };
}

function lowerCoordNP(np: Tree): Compound<Nominal> {
  let kids = np.children;
  let correlative: string | null = null;
  if (isCorrelative(kids[0]) && (kids[0]!.label === "DT" || kids[0]!.label === "CC")) {
    correlative = kids[0]!.word!.toLowerCase(); // "both Max and I" -> "both...and", not "both" on Max
    kids = kids.slice(1);
  }
  const groups: Tree[][] = [[]];
  let conjunction = "and";
  for (const c of kids) {
    if (isCC(c)) {
      if (c.word) conjunction = c.word;
      groups.push([]);
    } else if (isPunct(c)) {
      groups.push([]);
    } else {
      groups[groups.length - 1]!.push(c);
    }
  }
  const items = groups
    .filter((g) => g.length > 0)
    .map((g) => asNominal(lowerNP(g.length === 1 && g[0]!.label === "NP" ? g[0]! : { label: "NP", children: g })));
  return { items, conjunction: w(conjLabel(correlative, conjunction)) };
}

// --- prepositional & subordinate ---

function lowerPP(pp: Tree): Modifier {
  const prepTok = pp.children.find((c) => c.label === "IN" || c.label === "TO");
  const objNP = pp.children.find((c) => c.label === "NP");
  // an adverb qualifying the preposition ("especially in the winter") rides on the prep label
  const isAdv = (c: Tree) => c.label === "ADVP" || c.label === "RB";
  const adv = pp.children.filter(isAdv).map(phrase).join(" ");
  let object: Nominal;
  if (objNP) {
    object = asNominal(lowerNP(objNP));
  } else {
    // object is a clause/gerund ("after leaving Portugal") — use the words AFTER the preposition,
    // not phrase(pp), which would repeat the preposition itself.
    const rest = pp.children.filter((c) => c !== prepTok && !isAdv(c)).map(phrase).join(" ").trim();
    object = { head: w(rest || phrase(pp)), modifiers: [] };
  }
  const prepWord = prepTok?.word ?? phrase(pp).split(" ")[0] ?? "?";
  return { kind: "prep", prep: w(adv ? `${adv} ${prepWord}` : prepWord), object };
}

function lowerSBAR(sbar: Tree): Modifier {
  const wh = sbar.children.find((c) => ["WHNP", "WHADVP", "WHPP", "WDT", "WP", "WRB"].includes(c.label));
  const inConn = sbar.children.find((c) => c.label === "IN");
  const s = sbar.children.find((c) => c.label === "S" || c.label === "SINV" || c.label === "SQ");
  const fallback: Clause = { subject: { head: w("?"), modifiers: [] }, verb: { head: w("?"), modifiers: [] }, complement: null };
  if (!s) return { kind: "clause", connector: w(inConn ? phrase(inConn) : wh ? phrase(wh) : "that"), value: fallback };

  // Relative clause: the wh-word is the gapped subject ("the dog that barked"); the dotted
  // connector carries no separate word (the relativizer IS the clause's subject).
  if (wh && !s.children.some((c) => c.label === "NP")) {
    return { kind: "clause", connector: w(""), value: lowerClause(s, { head: w(phrase(wh)), modifiers: [] }) };
  }
  // Adverbial / complement clause ("because dogs barked"): the subordinator is the connector.
  return { kind: "clause", connector: w(inConn ? phrase(inConn) : wh ? phrase(wh) : "that"), value: lowerClause(s) };
}

// --- predicates ---

function lowerPredicate(vp: Tree): { verb: Predicate; complement: Complement | null } {
  // compound predicate: (VP (VP ...) (CC and) (VP ...)) — each conjunct keeps its own complement.
  const vpKids = vp.children.filter((c) => c.label === "VP");
  if (vp.children.some((c) => isCC(c) || c.label === "CONJP") && vpKids.length >= 2) {
    // Walk in order so a conjunctive adverb between the conjuncts ("barked loudly and [then]
    // jumped") attaches to the conjunct it precedes, instead of being dropped.
    let conjunction = "and";
    const conjps = vp.children.filter((c) => c.label === "CONJP").map(phrase); // "not only", "but also"
    const items: PredicatePart[] = [];
    let pendingAdv: Modifier[] = [];
    for (const c of vp.children) {
      if (isCC(c)) { if (c.word) conjunction = c.word; continue; }
      if (c.label === "CONJP") continue; // correlative marker(s) -> folded into the label below
      if (c.label === "ADVP" || c.label === "RB") { pendingAdv.push({ kind: "word", value: w(phrase(c)) }); continue; }
      if (c.label !== "VP") continue;
      const r = lowerPredicate(c);
      const verb = "items" in r.verb ? asVerbalFlat(r.verb) : r.verb;
      if (pendingAdv.length) { verb.modifiers = [...pendingAdv, ...verb.modifiers]; pendingAdv = []; }
      items.push({ verb, complement: r.complement });
    }
    if (pendingAdv.length && items.length) items[items.length - 1]!.verb.modifiers.push(...pendingAdv); // trailing
    if (conjps.length) conjunction = conjps.join("..."); // correlative "not only ... but also"
    return { verb: { items, conjunction: w(conjunction) }, complement: null };
  }

  // word-level coordinated verbs: "(VP (CC either) (VBZ complains) (CC or) (VBZ criticizes))" — no
  // VP children, just finite verbs joined by a conjunction. Only when there is nothing else to
  // attach (no objects/complements), so a shared-object coordination isn't mis-split.
  const bareVerbs = vp.children.filter((c) => c.word !== undefined && isVerb(c.label));
  if (
    vp.children.some(isCC) && bareVerbs.length >= 2 &&
    !vp.children.some((c) => ["VP", "NP", "ADJP", "S", "INF", "PP", "SBAR"].includes(c.label))
  ) {
    let conjunction = "and";
    const correlative = isCorrelative(vp.children[0]) && isCC(vp.children[0]!) ? vp.children[0]!.word!.toLowerCase() : null;
    for (const c of vp.children) if (isCC(c) && c.word && !CORREL.has(c.word.toLowerCase())) conjunction = c.word;
    const items: PredicatePart[] = bareVerbs.map((v) => ({ verb: { head: wt(v), modifiers: [] }, complement: null }));
    return { verb: { items, conjunction: w(conjLabel(correlative, conjunction)) }, complement: null };
  }

  const verbWords: string[] = [];
  const verbLeaves: Tree[] = [];
  const modifiers: Modifier[] = [];
  const objNPs: Tree[] = []; // object NPs in order; two => indirect + direct object
  let indirectObject: Nominal | undefined;
  const ocClauses: Tree[] = []; // verbless small clauses carrying an objective complement
  let complement: Complement | null = null;

  const walk = (node: Tree): void => {
    for (const c of node.children) {
      if (c.word !== undefined && (isVerb(c.label) || c.label === "TO")) { verbWords.push(c.word); verbLeaves.push(c); } // incl. infinitive "to"
      else if (c.label === "VP") walk(c); // auxiliary chain: "has been running"
      else if (c.label === "S" && c.children.some((x) => x.label === "VP") && !c.children.some((x) => x.label === "NP")) {
        const inner = c.children.find((x) => x.label === "VP"); // subjectless S = infinitive: "has to think about X"
        if (inner) walk(inner);
      }
      else if (c.label === "S" && !c.children.some((x) => x.label === "VP")) {
        ocClauses.push(c); // verbless small clause = objective complement ("named our daughter Alice")
      }
      else if (c.label === "S" && c.children.some((x) => x.label === "NP") && c.children.some((x) => x.label === "VP")) {
        complement = { kind: "directObject", value: lowerClause(c) }; // causative small clause ("made her students read four novels")
      }
      else if (c.label === "ADVP" || c.label === "RB") modifiers.push({ kind: "word", value: w(phrase(c)) });
      else if (c.label === "PRT" || c.label === "RP") modifiers.push({ kind: "word", value: w(phrase(c)) }); // phrasal-verb particle ("stood up")
      else if (c.label === "PP") modifiers.push(lowerPP(c));
      else if (c.label === "SBAR") modifiers.push(lowerSBAR(c));
      else if (c.label === "NP") objNPs.push(c); // resolved after the walk (copula / IO+DO / DO)
      else if (c.label === "INF") {
        complement = { kind: "directObject", value: lowerInfinitive(c) }; // infinitive object on a stand
      } else if (c.label === "ADJP" || c.label === "JJ") {
        const jjs = c.label === "JJ" ? [c] : c.children.filter((k) => k.label === "JJ");
        const cc = c.children.find((k) => k.label === "CC");
        if (jjs.length > 1 && cc) {
          complement = { kind: "predicateAdj", value: { items: jjs.map((j) => w(j.word ?? phrase(j))), conjunction: w(cc.word ?? "and") } };
        } else {
          complement = { kind: "predicateAdj", value: w(phrase(c)) };
        }
      }
    }
  };
  walk(vp);

  // Objective complement: a verbless small clause. It may carry both the object and the
  // complement ("makes [me happy]"), or just the complement, with the object as the preceding
  // sibling NP ("painted my room [red]").
  const ocClause = ocClauses[0];
  if (ocClause) {
    const scNPs = ocClause.children.filter((x) => x.label === "NP");
    const scAdj = ocClause.children.find((x) => x.label === "ADJP" || x.label === "JJ");
    let objectTree: Tree | undefined;
    let ocIsAdj: boolean;
    let ocTree: Tree | undefined;
    if (scNPs.length >= 1 && (scAdj || scNPs.length >= 2)) {
      objectTree = scNPs[0]; // small clause holds both DO and OC
      ocIsAdj = !!scAdj;
      ocTree = scAdj ?? scNPs[1];
    } else {
      objectTree = objNPs.pop(); // OC only; DO is the preceding sibling NP
      ocIsAdj = !!scAdj;
      ocTree = scAdj ?? scNPs[0];
    }
    if (objectTree && ocTree) {
      complement = {
        kind: "objectComplement",
        object: lowerNP(objectTree),
        oc: ocIsAdj ? w(phrase(ocTree)) : asNominal(lowerNP(ocTree)),
        ocIsAdj,
      };
    }
  }

  // Resolve object NPs, unless an ADJP/INF/objective-complement already claimed the complement slot.
  if (complement === null && objNPs.length) {
    if (isCopula(verbWords)) {
      complement = { kind: "predicateNoun", value: lowerNP(objNPs[objNPs.length - 1]!) };
    } else if (objNPs.length >= 2) {
      // ditransitive "gave the children homework": first NP is the indirect object.
      indirectObject = asNominal(lowerNP(objNPs[0]!));
      complement = { kind: "directObject", value: lowerNP(objNPs[objNPs.length - 1]!) };
    } else {
      complement = { kind: "directObject", value: lowerNP(objNPs[0]!) };
    }
  }

  const verbHead: Word = verbLeaves.length === 1 ? wt(verbLeaves[0]!) : w(verbWords.join(" ") || phrase(vp));
  return { verb: { head: verbHead, modifiers, ...(indirectObject ? { indirectObject } : {}) }, complement };
}

function lowerInfinitive(inf: Tree): Infinitive {
  const verb = inf.children.find((c) => c.label === "VB");
  const obj = inf.children.find((c) => c.label === "NP");
  const modifiers: Modifier[] = [];
  for (const c of inf.children) {
    if (c.label === "ADVP" || c.label === "RB") modifiers.push({ kind: "word", value: w(phrase(c)) });
    else if (c.label === "PP") modifiers.push(lowerPP(c));
  }
  return { kind: "infinitive", verb: w(verb?.word ?? phrase(inf)), object: obj ? asNominal(lowerNP(obj)) : null, modifiers };
}

const asVerbalFlat = (c: Compound<PredicatePart>): Verbal => ({ head: w(c.items.map((i) => i.verb.head.text).join(` ${c.conjunction.text} `)), modifiers: [] });

// A negative contraction stays FUSED in the verb head — src/nlp/tagger.ts leaves "isn't" as one
// token on purpose (the negation is still visible in the surface word, and lint/ir-query reads it
// back off the head), so the copula test has to look past a trailing "n't". Without this,
// "Growth isn't a destination" made "a destination" a DIRECT OBJECT rather than a predicate noun.
//
// Only be-form STEMS survive the strip, which is exactly the wanted narrowness: "doesn't" -> "does"
// and "won't" -> "wo" are not in COPULA, so a fused auxiliary or modal still takes an ordinary
// object. "ain't" has no stem to strip and is listed outright.
const FUSED_COPULA = new Set(["ain't"]);
const stripContractedNegation = (word: string): string => (/n't$/i.test(word) ? word.slice(0, -3) : word);
const isCopulaWord = (v: string): boolean => {
  const lc = v.toLowerCase();
  return COPULA.has(lc) || FUSED_COPULA.has(lc) || COPULA.has(stripContractedNegation(lc));
};
const isCopula = (verbWords: string[]) => verbWords.some(isCopulaWord);

// Gather adverb/PP modifiers from a verbal phrase (shared by gerund/infinitive lowering).
function verbalModifiers(src: Tree): Modifier[] {
  const mods: Modifier[] = [];
  for (const c of src.children) {
    if (c.label === "PP") mods.push(lowerPP(c));
    else if (c.label === "ADVP" || c.label === "RB") mods.push({ kind: "word", value: w(phrase(c)) });
  }
  return mods;
}

// A participial phrase modifying a noun: the VBG/VBN verb + object + adverb/PP modifiers.
function lowerParticipleVP(vp: Tree, leading: Tree[] = []): Modifier {
  const part = vp.children.find((c) => c.label === "VBG" || c.label === "VBN");
  const obj = vp.children.find((c) => c.label === "NP");
  const modifiers = [...leading.map((a) => ({ kind: "word", value: w(phrase(a)) } as Modifier)), ...verbalModifiers(vp)];
  return { kind: "participle", verb: w(part?.word ?? phrase(vp)), object: obj ? asNominal(lowerNP(obj)) : null, modifiers };
}

// A participial phrase set off as its own S: "(S (ADVP Cheerfully) (VP (VBG whistling) ...))".
const lowerParticipleS = (s: Tree): Modifier =>
  lowerParticipleVP(s.children.find((c) => c.label === "VP")!, s.children.filter((c) => c.label === "ADVP" || c.label === "RB"));

// A reduced clause acting as a participle ("the dog[,] barking furiously"): an S (or bare VP) with a
// VBG/VBN-headed VP and no subject NP. Distinct from a gerund subject only by having a sibling
// subject NP — the caller decides which reading applies.
function isParticipial(t: Tree): boolean {
  const vp = t.label === "VP" ? t : t.label === "S" && !t.children.some((c) => c.label === "NP") ? t.children.find((c) => c.label === "VP") : undefined;
  const head = vp?.children[0];
  return !!head && (head.label === "VBG" || head.label === "VBN");
}

// An absolute phrase ("Smoke alarms screaming, ...") — a noun with a participial VP, grammatically
// independent of the clause. Lowered to a nominal carrying the participle as a modifier.
function isAbsolute(t: Tree): boolean {
  if (t.label !== "S" || !t.children.some((c) => c.label === "NP")) return false;
  const head = t.children.find((c) => c.label === "VP")?.children[0];
  return !!head && (head.label === "VBG" || head.label === "VBN");
}
function lowerAbsolute(s: Tree): Nominal {
  const nominal = asNominal(lowerNP(s.children.find((c) => c.label === "NP")!));
  nominal.modifiers.push(lowerParticipleVP(s.children.find((c) => c.label === "VP")!));
  return nominal;
}

// A gerund subject/object: (S (VP (VBG Running) (NP marathons) (PP ...))).
function lowerGerund(vp: Tree): Gerund {
  const vbg = vp.children.find((c) => c.label === "VBG");
  const obj = vp.children.find((c) => c.label === "NP");
  return { kind: "gerund", verb: w(vbg?.word ?? phrase(vp)), object: obj ? asNominal(lowerNP(obj)) : null, modifiers: verbalModifiers(vp) };
}

// An infinitive subject: (S (VP (TO To) (VP (VB master) (NP a new skill)))).
function lowerInfinitiveFromVP(vp: Tree): Infinitive {
  const inner = vp.children.find((c) => c.label === "VP") ?? vp;
  const vb = inner.children.find((c) => isVerb(c.label) && c.word);
  const obj = inner.children.find((c) => c.label === "NP");
  return { kind: "infinitive", verb: w(vb?.word ?? phrase(inner)), object: obj ? asNominal(lowerNP(obj)) : null, modifiers: verbalModifiers(inner) };
}

// A noun clause (SBAR) used nominally: "Whatever you want", "Whoever made this pottery",
// "Where the sock had gone". Mirrors lowerSBARQ: the wh-word is the gapped subject, the gapped
// object, or (WHADVP) an adverbial modifier on the verb.
function lowerNounClause(sbar: Tree): Clause {
  const wh = sbar.children.find((c) => ["WHNP", "WHADVP", "WHPP"].includes(c.label));
  const s = sbar.children.find((c) => c.label === "S" || c.label === "SQ");
  if (!s) throw new Error("lower: noun clause without a clause");
  const whWord = wh ? phrase(wh) : "that";
  if (wh?.label === "WHNP" && !s.children.some((c) => c.label === "NP")) {
    return lowerClause(s, { head: w(whWord), modifiers: [] }); // wh is the gapped subject
  }
  const clause = lowerClause(s);
  if (wh?.label === "WHADVP" && "modifiers" in clause.verb) {
    clause.verb.modifiers.push({ kind: "word", value: w(whWord) }); // "Where ... gone"
  } else if (wh?.label === "WHNP" && !clause.complement) {
    clause.complement = { kind: "directObject", value: { head: w(whWord), modifiers: [] } }; // gapped object
  }
  return clause;
}

// The subject constituent may be an NP, a gerund/infinitive (S), or a noun clause (SBAR).
function lowerSubjectConstituent(t: Tree): Subject | null {
  if (t.label === "NP") return lowerNP(t);
  if (t.label === "SBAR") return lowerNounClause(t);
  if (t.label === "S") {
    const vp = t.children.find((c) => c.label === "VP");
    const first = vp?.children[0];
    if (first?.label === "TO") return lowerInfinitiveFromVP(vp!);
    if (first?.label === "VBG") return lowerGerund(vp!);
  }
  return null;
}

// --- clause ---

function lowerClause(s: Tree, fallbackSubject?: Subject): Clause {
  const vp = s.children.find((c) => c.label === "VP");
  if (!vp) throw new Error(`lower: unsupported clause (no VP) in (${s.label} ...)`);
  // The subject is the NP adjacent to the predicate; an earlier NP is a fronted adverbial ("Today
  // Darren left ..."). Only with no NP is a gerund/infinitive S or noun-clause SBAR the subject.
  const preVP = s.children.slice(0, s.children.indexOf(vp));
  const nps = preVP.filter((c) => c.label === "NP");
  const subjTree = nps[nps.length - 1] ?? preVP.find((c) => c.label === "S" || c.label === "SBAR");
  const subject = subjTree ? lowerSubjectConstituent(subjTree) ?? fallbackSubject : fallbackSubject; // relative clauses have a gapped subject
  if (!subject) throw new Error(`lower: unsupported clause (need NP + VP) in (${s.label} ...)`);
  // Participial phrases set off from the subject ("The dog, barking furiously, chased ...";
  // "Growling, the monster charged ...") modify the subject noun — attach them there.
  const participles = s.children.filter((c) => c !== subjTree && c !== vp && c.label === "S" && isParticipial(c)).map(lowerParticipleS);
  if (participles.length && "modifiers" in subject) subject.modifiers.push(...participles);
  const { verb, complement } = lowerPredicate(vp);
  // Fronted / adverbial siblings outside the VP — a temporal noun ("Today"), a fronted PP ("In old
  // tales, ..."), a fronted adverb clause ("because the field flooded, ..."), a clause-level adverb
  // ("your team really needs") — attach to the verb (the first conjunct if it is compound).
  const advTarget: Verbal | null = "modifiers" in verb ? verb : verb.items[0] ? verb.items[0].verb : null;
  if (advTarget) {
    for (const c of s.children) {
      if (c === subjTree || c === vp) continue;
      if (c.label === "PP") advTarget.modifiers.push(lowerPP(c));
      else if (c.label === "SBAR") advTarget.modifiers.push(lowerSBAR(c));
      else if (c.label === "ADVP" || c.label === "RB" || c.label === "NP") advTarget.modifiers.push({ kind: "word", value: w(phrase(c)) });
    }
  }
  // Interjections ("Man,", "Wow!") float on a detached line above the diagram, unconnected.
  const detached = s.children.filter((c) => c.label === "INTJ").map((c) => w(phrase(c)));
  // Absolute phrases ("Smoke alarms screaming, ...") are grammatically independent — drawn detached.
  const absolutes = s.children.filter((c) => c !== subjTree && c !== vp && isAbsolute(c)).map(lowerAbsolute);
  return { subject, verb, complement, ...(detached.length ? { detached } : {}), ...(absolutes.length ? { absolutes } : {}) };
}

// Yes/no question: (SQ (VBZ Is) (NP the sky) (ADJP blue)) — un-invert to subject + predicate.
function lowerSQ(sq: Tree): Clause {
  const kids = sq.children.filter((c) => c.label !== "." && c.label !== ",");
  const lead: Tree[] = []; // leading auxiliary/verb before the subject
  let i = 0;
  while (i < kids.length && /^(VB|MD|AUX)/.test(kids[i]!.label)) lead.push(kids[i++]!);
  const subjNP = kids[i]?.label === "NP" ? kids[i]! : undefined;
  if (subjNP) i++;
  const vp: Tree = { label: "VP", children: [...lead, ...kids.slice(i)] }; // synthetic declarative predicate
  const { verb, complement } = lowerPredicate(vp);
  return { subject: subjNP ? lowerNP(subjNP) : { head: w("?"), modifiers: [] }, verb, complement };
}

// Wh-question: (SBARQ (WHNP Who) (SQ ...)). The wh-word is the subject if the SQ has no inverted
// aux+subject ("Who chased the cat"), otherwise the gapped object ("What did the dog eat").
function lowerSBARQ(sbarq: Tree): Clause {
  const wh = sbarq.children.find((c) => ["WHNP", "WHADVP", "WHPP"].includes(c.label));
  const sq = sbarq.children.find((c) => c.label === "SQ" || c.label === "S");
  if (!sq) {
    // declarative-order question, often interjection-prefixed: SBARQ holds NP + VP directly
    if (sbarq.children.some((c) => c.label === "VP")) return lowerClause(sbarq);
    throw new Error("lower: SBARQ without a clause");
  }
  const whWord = wh ? phrase(wh) : "what";
  const sqKids = sq.children.filter((c) => c.label !== "." && c.label !== ",");
  if (sqKids[0]?.label === "VP") {
    const { verb, complement } = lowerPredicate(sqKids[0]!); // wh is the subject
    return { subject: { head: w(whWord), modifiers: [] }, verb, complement };
  }
  const clause = lowerSQ(sq); // inverted; wh is the object
  if (!clause.complement) clause.complement = { kind: "directObject", value: { head: w(whWord), modifiers: [] } };
  return clause;
}

// Dispatch a top-level constituent to the right lowering.
function lowerTop(t: Tree): Clause {
  if (t.label === "SQ") return lowerSQ(t);
  if (t.label === "SBARQ") return lowerSBARQ(t);
  // Imperative: a top-level clause with a VP but NO subject constituent at all -> implied "(you)".
  // (A gerund/infinitive/noun-clause subject is an S/SBAR, so those are NOT imperatives.)
  const SUBJECTY = new Set(["NP", "S", "SBAR", "SQ", "SBARQ"]);
  if ((t.label === "S" || t.label === "VP") && t.children.some((c) => c.label === "VP") && !t.children.some((c) => SUBJECTY.has(c.label))) {
    return lowerClause(t, { head: w("(you)"), modifiers: [] });
  }
  return lowerClause(t);
}

// --- public API ---

export function lower(parse: Tree | string): Clause {
  return lowerTop(typeof parse === "string" ? parseBracket(parse) : parse);
}

// Lower a whole sentence: a compound sentence (top-level S with several S children) becomes
// multiple clauses; anything else is a single-clause sentence.
export function lowerSentence(parse: Tree | string): Sentence {
  let t = typeof parse === "string" ? parseBracket(parse) : parse;
  // unwrap a ROOT/TOP/S1 wrapper (the neural parser returns a Tree object, not a string)
  while (["ROOT", "TOP", "S1", ""].includes(t.label) && t.children.length === 1 && t.children[0]) t = t.children[0];
  const sKids = t.children.filter((c) => c.label === "S" || c.label === "SINV");
  if (t.label === "S" && sKids.length >= 2) {
    let ccWords = t.children.filter((c) => c.label === "CC").map((c) => c.word ?? "and");
    // fold a leading correlative ("Either ... or ...") into the first conjunction label
    const correlative = ccWords[0] && CORREL.has(ccWords[0].toLowerCase()) ? ccWords.shift()!.toLowerCase() : null;
    const conjunctions = ccWords.map((cw, i) => w(i === 0 ? conjLabel(correlative, cw) : cw));
    const clauses = sKids.map((c) => lowerClause(c));
    // A fronted PP/adverb before the first clause ("In old tales, Grendel was ...") attaches there.
    const fronted = t.children.slice(0, t.children.indexOf(sKids[0]!)).filter((c) => c.label === "PP" || c.label === "ADVP");
    if (fronted.length && clauses[0] && "modifiers" in clauses[0].verb) {
      for (const f of fronted) clauses[0].verb.modifiers.push(f.label === "PP" ? lowerPP(f) : { kind: "word", value: w(phrase(f)) });
    }
    return { clauses, conjunctions };
  }
  return { clauses: [lowerTop(t)], conjunctions: [] };
}

// N-best: lower each candidate parse, dropping any that fail to lower.
export function lowerNBest(parses: Array<Tree | string>): Clause[] {
  const out: Clause[] = [];
  for (const p of parses) {
    try {
      out.push(lower(p));
    } catch {
      /* skip unsupported parse */
    }
  }
  return out;
}
