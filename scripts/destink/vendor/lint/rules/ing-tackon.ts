// Superficial "-ing" Tack-on (issue #18) — a dangling present-participle phrase glued onto the
// end of a sentence to inject shallow significance ("...opened in 1994, highlighting its
// importance."). The word list lives in src/lint/lexicons/superficial-ing-verbs.ts (imported
// below, never redefined here). Per that lexicon's own header comment, an ordinary "-ing" verb is
// not the tell — SYNTACTIC POSITION is: the verb must be (1) in the list, (2) sitting at/near the
// clause's end, and (3) hanging loosely off the clause (a trailing modifier on the subject or
// complement) rather than doing integrated work mid-sentence ("the dog barking furiously bit me"
// — real information, right where the action is). All three are required; any one alone is common
// and innocent.
//
// TWO DETECTION PATHS, because the rule-based parser doesn't reliably preserve the shape path 1
// needs (see PARSER GAP below):
//
//   PATH 1 — IR-based (confirmed, scored at the lexicon's own defaultSeverity, "low"). Looks for
//   Modifier{kind:"participle"} as the TRAILING modifier on the clause's subject or complement
//   nominal (lower.ts attaches a comma-set-off participial phrase to the subject this way — see
//   lower.ts's lowerClause, "Participial phrases set off from the subject"; the same shape covers
//   a participle trailing the complement). "Near the clause's end" is checked by estimating the
//   participle phrase's own word count (verb + object + its modifiers, recursively) and requiring
//   that count to reach the unit's last word once counted forward from the participle verb's own
//   position — since the Clause IR carries no offsets, this is an estimate, documented at
//   nominalWordCount below, not a token-exact reconstruction.
//
//   PATH 2 — token-shape fallback (candidate severity, i.e. lower than path 1 — it can't confirm
//   attachment or a real parse, only a surface pattern). Triggers on comma + a listed verb's -ing
//   surface form within MAX_TAIL_WORDS words of the unit's end, with no parse involved at all.
//   Applies only to units path 1 did NOT already confirm, so the same tack-on is never reported
//   twice under two different rule findings for one span.
//
// PARSER GAP — reported per #18's ground rules and since CLOSED in the engine (issue #33). For the
// exact example #18 asks about, `parse("The station opened in 1994, highlighting its importance.")`
// used to return `(S (NP The station) (VP (VBD opened) (PP in 1994)))` and drop the trailing
// phrase outright, so the lowered Clause carried no participle and only path 2 could catch it.
// parse.ts now keeps a comma-set-off "-ing" phrase and lower.ts hangs it on the subject, so path 1
// fires through readDocument — and path 2 stands down for that unit, as designed. Path 2 still
// carries units whose parse doesn't reach path 1's shape. See ing-tackon.test.ts's end-to-end
// describe block.

import nlp from "compromise";
import type { Clause, Compound, Modifier, Nominal } from "../../ir.js";
import type { DocAnalysis, Finding, Severity, Span, TropeRule, UnitAnalysis } from "../types.js";
import { POS_GATE_PREFIX, superficialIngVerbs } from "../lexicons/index.js";

// See serves-as.ts for the long-form rationale of this exact technique; duplicated here (not
// imported) so each rule file in this pair stays self-contained the way rules/demo.ts is.
function lemmaOf(word: string): string {
  const inf = nlp(`it ${word} that`).verbs().toInfinitive().text();
  const stripped = inf.replace(/^it\s+/i, "").replace(/\s+that$/i, "");
  return (stripped || word).toLowerCase();
}

const lastToken = (text: string): string => {
  const parts = text.trim().split(/\s+/);
  return (parts[parts.length - 1] ?? "").toLowerCase();
};

type Participle = Extract<Modifier, { kind: "participle" }>;

// The two places a trailing participle can hang for #18's purposes: the clause's subject, and its
// complement, when either is (or reduces to) a nominal. A gerund/infinitive/clause-shaped subject,
// or a predicateAdj complement, has no nominal to carry a trailing modifier and is skipped.
function hosts(clause: Clause): Array<Nominal | Compound<Nominal>> {
  const out: Array<Nominal | Compound<Nominal>> = [];
  const subj = clause.subject;
  if ("head" in subj || "items" in subj) out.push(subj);
  const c = clause.complement;
  if (c && (c.kind === "directObject" || c.kind === "predicateNoun") && ("head" in c.value || "items" in c.value)) {
    out.push(c.value);
  }
  return out;
}

// The LAST modifier on the host's (first, for a Compound) item, when it is a participle. "Last in
// the array" is what "hangs loosely off the clause" means structurally here — see the file header.
function trailingParticiple(host: Nominal | Compound<Nominal>): Participle | null {
  const items = "items" in host ? host.items : [host];
  const last = items[items.length - 1];
  const lastMod = last?.modifiers[last.modifiers.length - 1];
  return lastMod?.kind === "participle" ? lastMod : null;
}

// An approximate word count for a participle phrase (verb + object + its own modifiers,
// recursively) used ONLY to estimate whether the phrase reaches the unit's last word — the Clause
// IR carries no source offsets (src/lint/types.ts), so this is a count of Word-shaped leaves, not
// a token-exact reconstruction. "clause" modifiers count as 1 (the connector) rather than
// descending into an embedded clause, which would overcount for this rule's purposes.
function nominalWordCount(n: Nominal | Compound<Nominal>): number {
  const items = "items" in n ? n.items : [n];
  return items.reduce((sum, it) => sum + 1 + it.modifiers.reduce((m, mod) => m + modifierWordCount(mod), 0), 0);
}
function modifierWordCount(m: Modifier): number {
  switch (m.kind) {
    case "word":
      return 1;
    case "prep":
      return m.prep.text.trim().split(/\s+/).length + nominalWordCount(m.object);
    case "clause":
      return 1;
    case "participle":
      return 1 + (m.object ? nominalWordCount(m.object) : 0) + m.modifiers.reduce((s, x) => s + modifierWordCount(x), 0);
  }
}

// The word-index tolerance for "near the end": the position estimate above is approximate (it
// doesn't count determiners dropped by lowering, etc.), so a 1-word slop absorbs minor undercounts
// without opening the door to genuinely mid-sentence participles like "the dog barking furiously
// bit me" (there the shortfall is 3+ words, comfortably outside this slop — see the test file).
const POSITION_SLOP = 1;

function lastWordIndex(unit: UnitAnalysis, text: string): number {
  const tok = lastToken(text);
  for (let i = unit.words.length - 1; i >= 0; i--) if (unit.words[i]!.text.toLowerCase() === tok) return i;
  return -1;
}

function nearUnitEnd(unit: UnitAnalysis, participleVerbText: string, approxLen: number): boolean {
  const idx = lastWordIndex(unit, participleVerbText);
  return idx >= 0 && idx + approxLen >= unit.words.length - POSITION_SLOP;
}

// Locates a Word's surface text among the unit's word spans (see serves-as.ts's `locate` for the
// same technique and why it's needed — the Clause IR carries no offsets). Degrades to the unit's
// own span when the text can't be found.
function locate(unit: UnitAnalysis, text: string): Span {
  const tok = lastToken(text);
  const hit = unit.words.find((w) => w.text.toLowerCase() === tok);
  return hit ? hit.span : unit.span;
}

const bareEntry = (lemma: string) => superficialIngVerbs.entries.find((e) => typeof e.match === "string" && e.match === lemma);

// How many words after `unit.words[i]` remain before the unit ends — the fallback's own, cruder
// stand-in for "near the end" (path 1's nominalWordCount isn't available here; there's no parse).
const MAX_TAIL_WORDS = 6;

function precedingNonSpaceChar(text: string, pos: number): string | undefined {
  let i = pos - 1;
  while (i >= 0 && /\s/.test(text[i]!)) i--;
  return i >= 0 ? text[i] : undefined;
}

const SEVERITY_ORDER: Severity[] = ["candidate", "low", "medium", "high"];
const shiftSeverity = (s: Severity, delta: number): Severity => {
  const i = SEVERITY_ORDER.indexOf(s);
  return SEVERITY_ORDER[Math.min(SEVERITY_ORDER.length - 1, Math.max(0, i + delta))]!;
};

type Hit = { span: Span; verbText: string; origin: "ir" | "fallback" };

export const ingTackOnRule: TropeRule = {
  id: "ing-tackon",
  name: "Superficial -ing tack-on",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const hits: Hit[] = [];
    const irConfirmedUnits = new Set<UnitAnalysis>();

    // --- path 1: IR-based ---
    for (const unit of doc.units) {
      if (!unit.clauses) continue;
      for (const clause of unit.clauses) {
        for (const host of hosts(clause)) {
          const p = trailingParticiple(host);
          if (!p) continue;
          const lemma = lemmaOf(lastToken(p.verb.text));
          const entry = bareEntry(lemma);
          if (!entry) continue;
          if (entry.posGate && p.verb.pos && !p.verb.pos.startsWith(POS_GATE_PREFIX[entry.posGate])) continue;
          const approxLen = 1 + (p.object ? nominalWordCount(p.object) : 0) + p.modifiers.reduce((s, x) => s + modifierWordCount(x), 0);
          if (!nearUnitEnd(unit, p.verb.text, approxLen)) continue;
          hits.push({ span: locate(unit, p.verb.text), verbText: p.verb.text, origin: "ir" });
          irConfirmedUnits.add(unit);
        }
      }
    }

    // --- path 2: token-shape fallback (skips units path 1 already confirmed) ---
    for (const unit of doc.units) {
      if (irConfirmedUnits.has(unit)) continue;
      for (let i = 0; i < unit.words.length; i++) {
        const word = unit.words[i]!;
        if (!/ing$/i.test(word.text)) continue;
        if (precedingNonSpaceChar(doc.text, word.span.start) !== ",") continue;
        const entry = bareEntry(lemmaOf(word.text));
        if (!entry) continue;
        const tailWords = unit.words.length - 1 - i;
        if (tailWords > MAX_TAIL_WORDS) continue;
        hits.push({ span: word.span, verbText: word.text, origin: "fallback" });
      }
    }

    // Count first, judge second (rules/demo.ts's contract): density is a whole-document call,
    // computed once over every hit (both paths — they're the same trope) before severity is set.
    const dense = hits.length >= (superficialIngVerbs.densityThreshold ?? 1);
    const irSeverity = dense ? shiftSeverity(superficialIngVerbs.defaultSeverity, 1) : superficialIngVerbs.defaultSeverity;
    const fallbackSeverity = dense ? superficialIngVerbs.defaultSeverity : shiftSeverity(superficialIngVerbs.defaultSeverity, -1);

    return hits.map((h) => ({
      ruleId: "ing-tackon",
      span: h.span,
      severity: h.origin === "ir" ? irSeverity : fallbackSeverity,
      message: `“${h.verbText}” tacked on at the end`,
      explanation: `A trailing “, ${h.verbText.toLowerCase()} ...” bolts significance onto a sentence that already ended — it reads as analysis but says nothing the sentence didn't already say. Cut it, or make the claim its own sentence and back it up.`,
    }));
  },
};
