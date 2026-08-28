// FALSE RANGE — "from X to Y" where X and Y aren't on any real scale ("from innovation to
// cultural transformation"). Issue #19.
//
// Judging whether X..Y is a real scale is semantic; this rule only narrows the field. Two
// independent detectors feed one severity ladder:
//
//   IR path     Walks the lowered Clause looking for a from-PP whose neighborhood (the same
//               modifier list, or recursively the from-PP's own object's modifiers) holds a
//               matching to-PP — including a chain ("from A to B to C"). Confirmed structure, so
//               a clean hit starts at "candidate" and gets UPGRADED to "low"/"medium" by three
//               heuristics (see scoreHeuristics below): both ends abstract-suffixed, 3+ items
//               strung along the range, and no shared unit/dimension between the ends.
//
//   Token path  A plain scan over unit.words for "from" ... "to" within a modest window, with no
//               tree required. It catches everything the rule-based chunker mangles or refuses
//               (run-on coordinations, fragments), but with no structure to confirm it against,
//               its findings are ALWAYS "candidate" — never upgraded.
//
// Both paths apply the same downgrade: a numeric end (digit or spelled-out small number, or a CD
// tag), a capitalized proper-noun end (place-to-place), or a known idiom (start to finish, top to
// bottom, time to time, head to toe, 9 to 5) suppresses the finding entirely — these are literal
// ranges, not false ones.
//
// Span: from the "from" token through the end of the range's last object, resolved by matching
// word text against unit.words (which carries source offsets); when that lookup fails (the object
// doesn't appear as a single token — e.g. a coordinated object flattened to a multi-word head by
// lower.ts's asNominal) the span degrades to the whole unit.

import type { Compound, Clause, Complement, Modifier, Nominal, Predicate, Subject, Verbal, Word } from "../../ir.js";
import type { DocAnalysis, Finding, Severity, Span, TropeRule, UnitAnalysis, WordSpan } from "../types.js";
import { spanning, overlaps } from "../span.js";

const RULE_ID = "false-range/from-to";

// --- shared word-level checks (both paths) ---

const NUMBER_WORDS = new Set([
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
]);
const isNumericText = (text: string): boolean => /^\d+$/.test(text) || NUMBER_WORDS.has(text.toLowerCase());
const isProperText = (text: string): boolean => /^[A-Z]/.test(text);

// Small, deliberately narrow: literal ranges that would otherwise trip the structural heuristics
// (both ends common nouns, no shared dimension) but are idiomatic, not rhetorical.
const IDIOMS: ReadonlyArray<readonly [string, string]> = [
  ["start", "finish"],
  ["top", "bottom"],
  ["time", "time"],
  ["head", "toe"],
  ["9", "5"],
];
const isIdiomPair = (a: string, b: string): boolean =>
  IDIOMS.some(([x, y]) => x === a.toLowerCase() && y === b.toLowerCase());

// --- IR path ---

type RangeCandidate = { fromWord: Word; endpoints: Nominal[] }; // endpoints[0] is the from-object

const bareWord = (text: string): string => {
  const parts = text.trim().split(/\s+/);
  return (parts[parts.length - 1] ?? "").toLowerCase();
};

// How many sibling modifiers we'll look past, from a "from"-PP, to find its matching "to"(s). Kept
// small on purpose — this is structure-narrowing, not a free-form search of the whole clause.
const MAX_MOD_GAP = 4;

// Scans one modifiers list for from -> to (-> to ...) chains; recursion into nested lists (a PP's
// own object, a nested clause, a participle) happens in the walk* functions below, which call this
// at every list they visit.
function scanModifiers(mods: Modifier[], out: RangeCandidate[]): void {
  for (let i = 0; i < mods.length; i++) {
    const m = mods[i]!;
    if (m.kind !== "prep" || bareWord(m.prep.text) !== "from") continue;
    const endpoints: Nominal[] = [m.object];
    const limit = Math.min(mods.length, i + 1 + MAX_MOD_GAP);
    for (let j = i + 1; j < limit; j++) {
      const next = mods[j]!;
      if (next.kind !== "prep") continue;
      const w = bareWord(next.prep.text);
      if (w === "from") break; // a new range starts — don't reach across it
      if (w === "to") endpoints.push(next.object);
    }
    // The OTHER neighborhood the issue calls out: a "to" living inside the from-PP's own object's
    // modifiers, not as a sibling of "from" itself.
    for (const inner of m.object.modifiers) {
      if (inner.kind === "prep" && bareWord(inner.prep.text) === "to") endpoints.push(inner.object);
    }
    if (endpoints.length >= 2) out.push({ fromWord: m.prep, endpoints });
  }
}

const asItems = <T>(n: T | Compound<T>): T[] => ("items" in (n as Compound<T>) ? (n as Compound<T>).items : [n as T]);

function walkNominal(n: Nominal | Compound<Nominal>, out: RangeCandidate[]): void {
  for (const item of asItems(n)) walkModifiers(item.modifiers, out);
}

function walkModifiers(mods: Modifier[], out: RangeCandidate[]): void {
  scanModifiers(mods, out);
  for (const m of mods) {
    if (m.kind === "prep") walkNominal(m.object, out);
    else if (m.kind === "clause") walkClause(m.value, out);
    else if (m.kind === "participle") {
      walkModifiers(m.modifiers, out);
      if (m.object) walkNominal(m.object, out);
    }
  }
}

function walkVerbal(v: Verbal, out: RangeCandidate[]): void {
  walkModifiers(v.modifiers, out);
  if (v.indirectObject) walkNominal(v.indirectObject, out);
}

function walkPredicate(p: Predicate, out: RangeCandidate[]): void {
  if ("items" in p) {
    for (const part of p.items) {
      walkVerbal(part.verb, out);
      if (part.complement) walkComplement(part.complement, out);
    }
    return;
  }
  walkVerbal(p, out);
}

function walkComplement(c: Complement, out: RangeCandidate[]): void {
  switch (c.kind) {
    case "predicateNoun":
      walkNominal(c.value, out);
      return;
    case "predicateAdj":
      return; // Word | Compound<Word> — nothing to recurse into
    case "objectComplement":
      walkNominal(c.object, out);
      if (!c.ocIsAdj) walkNominal(c.oc as Nominal, out);
      return;
    case "directObject": {
      const v = c.value;
      if ("items" in v) walkNominal(v, out); // Compound<Nominal>
      else if ("kind" in v) {
        // Infinitive ("wanted to leave")
        walkModifiers(v.modifiers, out);
        if (v.object) walkNominal(v.object, out);
      } else if ("head" in v) {
        walkNominal(v, out); // Nominal
      } else {
        walkClause(v, out); // Clause (causative small clause)
      }
    }
  }
}

function walkSubject(s: Subject, out: RangeCandidate[]): void {
  if ("items" in s) {
    for (const item of s.items) walkNominal(item, out);
  } else if ("kind" in s) {
    walkModifiers(s.modifiers, out); // Infinitive | Gerund
    if (s.object) walkNominal(s.object, out);
  } else if ("head" in s) {
    walkNominal(s, out); // Nominal
  } else {
    walkClause(s, out); // a full clause used nominally ("Whoever made this...")
  }
}

function walkClause(clause: Clause, out: RangeCandidate[]): void {
  walkSubject(clause.subject, out);
  walkPredicate(clause.verb, out);
  if (clause.complement) walkComplement(clause.complement, out);
}

// --- heuristics (IR path only — see module doc) ---

const ABSTRACT_SUFFIXES = ["tion", "ment", "ness", "ity", "ism", "ance", "ence"];
const hasAbstractSuffix = (text: string): boolean => {
  const lc = text.toLowerCase();
  return ABSTRACT_SUFFIXES.some((suf) => lc.length > suf.length + 2 && lc.endsWith(suf));
};

// Endpoints with a recognizable shared dimension — a real scale, not a "no shared unit" false
// range — even though neither is numeric, proper, or an idiom pair on its own.
const DIMENSION_WORDS = new Set([
  "top", "bottom", "start", "finish", "beginning", "end", "head", "toe",
  "north", "south", "east", "west", "left", "right", "inside", "outside",
  "morning", "evening", "dawn", "dusk", "sunrise", "sunset",
  "childhood", "adulthood", "birth", "death",
  "spring", "summer", "fall", "autumn", "winter",
]);

// A coordinated object gets flattened by lower.ts's asNominal into one head text joined by its
// conjunction ("discovery and expression and innovation") — this recovers an item count from that.
const coordinatedItemCount = (text: string): number => text.split(/\s+(?:and|or)\s+/i).length;

function scoreHeuristics(endpoints: Nominal[]): number {
  const first = endpoints[0]!.head.text;
  const last = endpoints[endpoints.length - 1]!.head.text;
  let hits = 0;
  if (hasAbstractSuffix(first) && hasAbstractSuffix(last)) hits++;
  const itemCount = Math.max(endpoints.length, coordinatedItemCount(first), coordinatedItemCount(last));
  if (itemCount >= 3) hits++;
  const known = (t: string) => DIMENSION_WORDS.has(t.toLowerCase());
  if (!known(first) && !known(last)) hits++;
  return hits;
}

const severityFor = (hits: number): Severity => (hits >= 2 ? "medium" : hits === 1 ? "low" : "candidate");

const isSuppressedEndpoint = (w: Word): boolean =>
  w.pos === "CD" || w.pos === "NNP" || w.pos === "NNPS" || isNumericText(w.text) || isProperText(w.text);

const isSuppressedIrPair = (first: Word, last: Word): boolean =>
  isSuppressedEndpoint(first) || isSuppressedEndpoint(last) || isIdiomPair(first.text, last.text);

// --- span resolution: map the IR's Words back onto unit.words for source offsets ---

function findWordSpan(words: WordSpan[], text: string, fromIndex: number): { index: number; span: Span } | null {
  const lc = text.toLowerCase();
  for (let i = fromIndex; i < words.length; i++) {
    if (words[i]!.text.toLowerCase() === lc) return { index: i, span: words[i]!.span };
  }
  return null;
}

// Resolves from "from" (searched no earlier than `cursor`, so repeated ranges in one unit don't
// all latch onto the first "from") through the last word of `lastHeadText` (the range's final
// object head — for a head-final NP that's the object's own last token). Degrades to the whole
// unit span when either lookup fails — e.g. a coordinated object whose head text is a multi-word
// join and so never appears as a single source token.
function resolveSpan(unit: UnitAnalysis, cursor: number, lastHeadText: string): { span: Span; next: number } {
  const fromHit = findWordSpan(unit.words, "from", cursor);
  if (!fromHit) return { span: unit.span, next: cursor };
  const lastToken = lastHeadText.trim().split(/\s+/).pop() ?? lastHeadText;
  const endHit = findWordSpan(unit.words, lastToken, fromHit.index + 1);
  if (!endHit) return { span: unit.span, next: fromHit.index + 1 };
  return { span: spanning([fromHit.span, endHit.span]), next: endHit.index + 1 };
}

// --- messages ---

function buildFinding(span: Span, x: string, y: string, hits: number): Finding {
  const severity = severityFor(hits);
  if (hits === 0) {
    return {
      ruleId: RULE_ID,
      span,
      severity,
      message: `"from ${x} to ${y}" has the shape of a range`,
      explanation: `"From ${x} to ${y}" borrows the form of a scale — a beginning point and an end — without anything confirming ${x} and ${y} sit on one measurable line. If they don't, say what actually changed instead of implying a spectrum.`,
    };
  }
  const reasons: string[] = [];
  if (hasAbstractSuffix(x) && hasAbstractSuffix(y)) reasons.push("both ends are abstract nouns");
  reasons.push("the two ends share no unit or dimension");
  return {
    ruleId: RULE_ID,
    span,
    severity,
    message: `"from ${x} to ${y}" is a false range`,
    explanation: `${x} and ${y} aren't points on the same scale (${reasons.join("; ")}). "From X to Y" reads as measurement, but this pairs two unrelated ideas — name the change directly instead.`,
  };
}

function tokenFinding(span: Span, x: string, y: string): Finding {
  return {
    ruleId: RULE_ID,
    span,
    severity: "candidate",
    message: `"from ${x} to ${y}" reads like a range`,
    explanation: `Word order alone suggests a range here, but nothing confirmed the structure. Check that ${x} and ${y} are actually two points on one scale — if not, this is a false range dressed up as one.`,
  };
}

// --- token path ---

const MAX_GAP = 16; // words allowed between "from" and its "to"(s) before giving up on the pair
const MAX_RANGE_WORDS = 10; // words captured as the range's tail object, past the last "to"
const LEADING_DET = new Set(["a", "an", "the"]);

// The representative word for Y-side suppression checks: skip a leading article so "the bottom"
// keys off "bottom", not "the". Not a claim about where the head of the NP actually is (it isn't,
// in general) — just enough to catch the idiom/numeric/proper cases the suppression list cares
// about without a tree.
function firstContentToken(tokens: WordSpan[]): WordSpan {
  const [first, second] = tokens;
  if (first && second && LEADING_DET.has(first.text.toLowerCase())) return second;
  return first!;
}

function tokenPathCandidates(unit: UnitAnalysis): Finding[] {
  const words = unit.words;
  const findings: Finding[] = [];
  let i = 0;
  while (i < words.length) {
    if (words[i]!.text.toLowerCase() !== "from") {
      i++;
      continue;
    }
    const fromIdx = i;
    const limit = Math.min(words.length, fromIdx + 1 + MAX_GAP);
    const toIdxs: number[] = [];
    for (let j = fromIdx + 1; j < limit; j++) if (words[j]!.text.toLowerCase() === "to") toIdxs.push(j);
    if (toIdxs.length === 0) {
      i = fromIdx + 1;
      continue;
    }
    const firstTo = toIdxs[0]!;
    const lastTo = toIdxs[toIdxs.length - 1]!;
    if (firstTo <= fromIdx + 1) {
      i = fromIdx + 1;
      continue;
    }
    const xTokens = words.slice(fromIdx + 1, firstTo);
    const yEnd = Math.min(words.length, lastTo + 1 + MAX_RANGE_WORDS);
    const yTokens = words.slice(lastTo + 1, yEnd);
    if (xTokens.length === 0 || yTokens.length === 0) {
      i = fromIdx + 1;
      continue;
    }
    const xLast = xTokens[xTokens.length - 1]!;
    const yRep = firstContentToken(yTokens);
    const suppressed = isNumericText(xLast.text) || isNumericText(yRep.text) ||
      isProperText(xLast.text) || isProperText(yRep.text) || isIdiomPair(xLast.text, yRep.text);
    if (!suppressed) {
      const yLast = yTokens[yTokens.length - 1]!;
      findings.push(tokenFinding(spanning([words[fromIdx]!.span, yLast.span]), xLast.text, yRep.text));
    }
    i = lastTo + 1;
  }
  return findings;
}

// --- rule ---

export const falseRangeRule: TropeRule = {
  id: RULE_ID,
  name: 'False range ("from X to Y")',
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const findings: Finding[] = [];
    for (const unit of doc.units) {
      const irFindings: Finding[] = [];
      if (unit.clauses && unit.clauses.length > 0) {
        const candidates: RangeCandidate[] = [];
        for (const clause of unit.clauses) walkClause(clause, candidates);
        let cursor = 0;
        for (const cand of candidates) {
          const first = cand.endpoints[0]!.head;
          const last = cand.endpoints[cand.endpoints.length - 1]!.head;
          if (isSuppressedIrPair(first, last)) continue;
          const { span, next } = resolveSpan(unit, cursor, last.text);
          cursor = next;
          const hits = scoreHeuristics(cand.endpoints);
          irFindings.push(buildFinding(span, first.text, last.text, hits));
        }
      }
      const tokenFindings = tokenPathCandidates(unit).filter(
        (tf) => !irFindings.some((irf) => overlaps(irf.span, tf.span)),
      );
      findings.push(...irFindings, ...tokenFindings);
    }
    return findings;
  },
};
