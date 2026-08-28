// The rule runner. Rules are predicates over the WHOLE document that return located findings —
// the game's Condition with the polarity flipped: instead of "does this sentence pass?", it is
// "where does this document tell on itself?".
//
// Seeing the whole document is the point. A prompt-based judge reading sentence by sentence cannot
// say "one tricolon is style, three in a row is a pattern"; a rule holding every unit can, so
// density thresholds live inside detect() and the runner stays dumb.
//
// What the runner guarantees, so rules do not have to:
//
//   Order      Findings come back in document order: span.start asc, then span.end asc (a nested
//              finding precedes the wider one around it), then ruleId by code point. Never
//              localeCompare — the order must not depend on the machine's locale. Those three keys
//              are a total order after dedupe, so two runs over the same input produce the exact
//              same array. No secondary sort on message or severity is needed or applied.
//
//   Dedupe     Identical ruleId AND identical span = the same tell reported twice; the first one
//              wins (first in the order the rules were passed in) and the rest are dropped. That
//              is the ONLY thing dropped. Overlapping spans survive — from different rules, because
//              two tells can legitimately land on the same words ("It's not X — it's Y" is both
//              negative parallelism and an em dash), and from the SAME rule, because a rule may
//              nest findings (a tricolon inside a tricolon). A rule that wants to report two
//              different things about the exact same span must split into two rule ids.
//
//   Isolation  A rule that throws does not kill the run. Its exception is caught, recorded in
//              result.errors, and every other rule still reports. A rule that throws contributes
//              NO findings, not even the ones it returned before throwing — detect() is
//              all-or-nothing, so a half-finished rule cannot half-report.
//
//   Sanity     A finding whose span does not fit the document (start > end, or outside
//              [0, text.length]) is dropped and recorded as an error against its rule. A bad span
//              would otherwise surface as a broken highlight in the UI, far from the rule that
//              caused it.

import type { DocAnalysis, Finding, TropeRule } from "./types.js";
import { compareSpans } from "./span.js";

// A rule that misbehaved. `message` is a one-liner safe to show in the UI; `error` is the thrown
// value (usually an Error, with its stack) for the console.
export type RuleError = { ruleId: string; message: string; error: unknown };

// Findings in document order plus whatever went wrong, in the order the rules were run. Callers
// that only want the findings read `.findings`; the app surfaces `.errors` so a broken rule is
// visible instead of silently producing nothing.
export type LintResult = { findings: Finding[]; errors: RuleError[] };

// Exported so a UI that re-groups findings (by tier, by severity) can restore document order.
export const compareFindings = (a: Finding, b: Finding): number =>
  compareSpans(a.span, b.span) || (a.ruleId < b.ruleId ? -1 : a.ruleId > b.ruleId ? 1 : 0);

const describe = (err: unknown): string => (err instanceof Error ? err.message : String(err));

// The dedupe key. Length-prefixed so no id containing the separator can collide with another's
// key, and keyed on the FINDING's own ruleId, not the rule's — one module may emit under sub-ids.
const dedupeKey = (f: Finding): string => `${f.ruleId.length}:${f.ruleId}:${f.span.start}:${f.span.end}`;

export function runRules(rules: readonly TropeRule[], doc: DocAnalysis): LintResult {
  const findings: Finding[] = [];
  const errors: RuleError[] = [];
  const seen = new Set<string>(); // first finding for a key wins

  for (const rule of rules) {
    let produced: Finding[];
    try {
      produced = rule.detect(doc);
    } catch (err) {
      errors.push({ ruleId: rule.id, message: `rule threw: ${describe(err)}`, error: err });
      continue; // all-or-nothing: a throwing rule reports nothing
    }
    for (const f of produced) {
      const { start, end } = f.span;
      if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start || end > doc.text.length) {
        const bad = `span [${start}, ${end}) does not fit a ${doc.text.length}-char document`;
        errors.push({ ruleId: rule.id, message: `dropped a finding: ${bad}`, error: new Error(bad) });
        continue;
      }
      const key = dedupeKey(f);
      if (seen.has(key)) continue;
      seen.add(key);
      findings.push(f);
    }
  }

  findings.sort(compareFindings);
  return { findings, errors };
}
