// Tricolon abuse — rule-of-three density. `Compound<T>` (src/ir.ts) already models "X, Y, and Z"
// structurally: items.length >= 3 is exactly a tricolon (or a longer list) sitting in a subject,
// predicate, object, or modifier slot anywhere in the clause. This rule walks the whole Clause IR
// of every lowered unit — a small recursive walker over subjects, predicates, complements and
// modifiers, since none of the existing modules (ir-query.ts asks yes/no questions of ONE clause;
// span.ts is offset arithmetic) provide one — and counts every compound of 3+ items it finds.
//
// Compound IR nodes carry no source offsets (a `Word` is only `{ text, pos }` — see src/ir.ts),
// so every finding here degrades to its enclosing UNIT's span, per the issue's guidance for rules
// that lack word-level spans.
//
// Two independent triggers:
//   - A 4-or-5(+)-item compound is flagged on its own, every time, at a higher severity than a
//     bare triple: "three things" is ordinary rhetoric and not itself a tell (see the "1 tricolon
//     clean" acceptance case), but four or five in one series already reads as a list dressed up
//     as a sentence, even in isolation.
//   - Document-level density: three or more tricolons ANYWHERE in the document (triples and
//     larger, all counted together) is the actual trope — "three back-to-back tricolons are a
//     pattern recognition failure." That finding's span covers the WHOLE document (chosen over
//     "the third instance" — the pattern is a document-wide property, and a whole-document span
//     stays correct and unambiguous no matter how the three are spread across units).
//
// This rule emits under two ruleIds ("tricolon/density" for the per-compound findings,
// "tricolon/document-density" for the whole-document one) — the engine's dedupe keys on a
// finding's OWN ruleId, so one module reporting under sub-ids is an intended shape (see
// engine.ts's dedupe comment).

import type { Clause, Complement, Gerund, Infinitive, Modifier, Nominal, Predicate, Subject, Verbal } from "../../ir.js";
import type { DocAnalysis, Finding, TropeRule } from "../types.js";

const RULE_ID = "tricolon/density";
const DOC_RULE_ID = "tricolon/document-density";

const LARGE_AT = 4; // 4+ items get their own finding, independent of document density
const DOC_DENSITY_AT = 3; // 3+ tricolons anywhere in the document trips the document-level finding

type Hit = { count: number };

function walkModifiers(mods: Modifier[], out: Hit[]): void {
  for (const m of mods) {
    if (m.kind === "prep") walkNominal(m.object, out);
    else if (m.kind === "clause") walkClause(m.value, out);
    else if (m.kind === "participle") {
      if (m.object) walkNominal(m.object, out);
      walkModifiers(m.modifiers, out);
    }
    // m.kind === "word": a bare Word, nothing further to walk
  }
}

function walkNominal(n: Nominal, out: Hit[]): void {
  walkModifiers(n.modifiers, out);
}

function walkVerbal(v: Verbal, out: Hit[]): void {
  walkModifiers(v.modifiers, out);
  if (v.indirectObject) walkNominal(v.indirectObject, out);
}

function walkInfinitiveOrGerund(v: Infinitive | Gerund, out: Hit[]): void {
  walkModifiers(v.modifiers, out);
  if (v.object) walkNominal(v.object, out);
}

function walkSubject(s: Subject, out: Hit[]): void {
  if ("items" in s) {
    out.push({ count: s.items.length });
    for (const item of s.items) walkNominal(item, out);
    return;
  }
  if ("head" in s) {
    walkNominal(s, out); // Nominal
    return;
  }
  if ("kind" in s) {
    walkInfinitiveOrGerund(s, out); // Infinitive | Gerund
    return;
  }
  walkClause(s, out); // a whole clause used nominally ("Whoever made this...")
}

function walkComplement(c: Complement | null, out: Hit[]): void {
  if (!c) return;
  switch (c.kind) {
    case "directObject": {
      const v = c.value;
      if ("items" in v) {
        out.push({ count: v.items.length });
        for (const item of v.items) walkNominal(item, out);
      } else if ("head" in v) {
        walkNominal(v, out); // Nominal
      } else if ("kind" in v) {
        walkInfinitiveOrGerund(v, out); // Infinitive
      } else {
        walkClause(v, out); // a causative small clause ("made her students read four novels")
      }
      return;
    }
    case "predicateNoun": {
      const v = c.value;
      if ("items" in v) {
        out.push({ count: v.items.length });
        for (const item of v.items) walkNominal(item, out);
      } else {
        walkNominal(v, out);
      }
      return;
    }
    case "predicateAdj": {
      const v = c.value;
      if ("items" in v) out.push({ count: v.items.length }); // Compound<Word> — a Word has no further nesting
      return;
    }
    case "objectComplement": {
      const obj = c.object;
      if ("items" in obj) {
        out.push({ count: obj.items.length });
        for (const item of obj.items) walkNominal(item, out);
      } else {
        walkNominal(obj, out);
      }
      if (!c.ocIsAdj) walkNominal(c.oc as Nominal, out);
      return;
    }
  }
}

function walkPredicate(p: Predicate, out: Hit[]): void {
  if ("items" in p) {
    out.push({ count: p.items.length });
    for (const part of p.items) {
      walkVerbal(part.verb, out);
      walkComplement(part.complement, out);
    }
    return;
  }
  walkVerbal(p, out);
}

function walkClause(clause: Clause, out: Hit[]): void {
  walkSubject(clause.subject, out);
  walkPredicate(clause.verb, out);
  walkComplement(clause.complement, out);
  for (const a of clause.absolutes ?? []) walkNominal(a, out);
}

function collectTricolons(clauses: Clause[]): Hit[] {
  const out: Hit[] = [];
  for (const c of clauses) walkClause(c, out);
  return out.filter((h) => h.count >= 3);
}

export const tricolonRule: TropeRule = {
  id: RULE_ID,
  name: "Tricolon abuse (rule-of-three density)",
  tier: "syntactic",
  detect(doc: DocAnalysis): Finding[] {
    const findings: Finding[] = [];
    let total = 0;
    for (const unit of doc.units) {
      if (!unit.clauses || unit.clauses.length === 0) continue;
      const hits = collectTricolons(unit.clauses);
      total += hits.length;
      for (const h of hits) {
        if (h.count < LARGE_AT) continue;
        findings.push({
          ruleId: RULE_ID,
          span: unit.span,
          severity: h.count >= LARGE_AT + 1 ? "high" : "medium",
          message: `a ${h.count}-item list — past a tricolon, into padding`,
          explanation: `Three items reads as rhetoric; ${h.count} in one series reads like a list dressed up as a sentence. Cut it to three, or make it an actual list.`,
        });
      }
    }
    if (total >= DOC_DENSITY_AT) {
      findings.push({
        ruleId: DOC_RULE_ID,
        span: { start: 0, end: doc.text.length },
        severity: "medium",
        message: `${total} rule-of-three constructions in this document`,
        explanation: `A tricolon here and there is ordinary rhetoric; ${total} of them in one piece is a tic. Vary the sentence shapes — not every list needs to come in exactly three.`,
      });
    }
    return findings;
  },
};
