// ELEGANT VARIATION (claude-isms tier, #34) — the inverse of repetition.ts. Where dilution flags a
// writer saying the same thing over and over, this flags a writer refusing to say the same WORD
// twice: one referent cycled through a thesaurus so no noun has to appear a second time.
//
//   "The vehicle arrived late that morning. This automobile had been repainted twice.
//    Said car was finally towed away."
//
// Nothing was clarified by the second and third names; the reader now has to check whether three
// objects are being tracked or one. Fowler named the habit a century ago and it is a strong tell in
// generated prose, which reaches for a synonym the moment a word has been used.
//
// --- how it is detected without embeddings ---
// No vector model ships to the browser build, so "these two nouns mean the same thing" comes from a
// small, curated, hand-written table instead: CLUSTERS below, a dozen-odd groups of everyday
// synonyms. It is deliberately data, not code — adding a cluster is one array entry, and the table
// is meant to grow. What the rule looks for:
//
//   phrase   a DETERMINER immediately (or nearly) followed by a cluster member: "the vehicle",
//            "this automobile", "that car", "said car". The determiner requirement is what makes
//            the phrase a REFERENCE to a specific thing rather than a generic mention — "cars are
//            expensive" is a claim about cars, not a way of avoiding the word "car". Up to
//            MAX_GAP tokens are allowed between the two so an adjective ("the repainted vehicle")
//            does not hide the noun.
//   window   the phrases have to be close together: WINDOW consecutive units. Two synonyms a page
//            apart are two mentions, not a cycle.
//   cycling  at least MIN_DISTINCT distinct head nouns from ONE cluster, each occurring EXACTLY
//            ONCE inside the window. The exactly-once test is the point of the rule: a writer who
//            says "the car" three times is repeating, which is fine here (dilution owns that), and
//            a writer who says "the car ... the vehicle ... the car" is alternating, not cycling.
//
// --- what it deliberately does not catch ---
//   * two synonyms only ("the vehicle ... this automobile"). Two names for one thing is often just
//     a sentence that needed a different word; three is a pattern.
//   * synonyms outside the table. There is no general synonymy here and there cannot be without a
//     model — every miss of that kind is a missing cluster, and the fix is an entry in CLUSTERS.
//   * bare plurals and determinerless mentions ("vehicles ... automobiles ... cars"), for the
//     reason above: no determiner, no single referent being tracked.
//
// Severity: "low" per cycling cluster, bumped to "medium" for every finding once two or more
// DIFFERENT clusters cycle in the same document — one referent given three names can be a stylistic
// slip, two referents both being cycled is the writing habit.

import type { DocAnalysis, Finding, Severity, Span, TropeRule, WordSpan } from "../types.js";
import { spanning } from "../span.js";

const RULE_ID = "claude/elegant-variation";

const WINDOW = 4; // consecutive units a cycle has to fit inside
const MIN_DISTINCT = 3; // distinct synonyms before a cycle is a cycle
const MAX_GAP = 2; // tokens allowed between the determiner and the noun ("the freshly repainted car")

// Determiners that make the following noun a reference to one specific thing. "said" is the legal-
// register variant that shows up in exactly this trope ("said car"); "such" likewise.
const DETERMINERS = new Set(["the", "this", "that", "these", "those", "said", "such"]);

// --- the synonym table --------------------------------------------------------------------------
// Hand-curated, shipped as data, extensible: add a group and the rule covers it. Kept to everyday
// referents a writer actually cycles; technical vocabulary is left out because a genuine term of
// art repeating is not this trope.
const CLUSTERS: readonly (readonly string[])[] = [
  ["vehicle", "car", "automobile", "auto", "motorcar"],
  ["dog", "canine", "hound", "pooch", "mutt"],
  ["house", "home", "residence", "dwelling", "abode"],
  ["company", "firm", "organization", "organisation", "enterprise", "corporation"],
  ["report", "document", "paper", "dossier", "memo"],
  ["city", "metropolis", "municipality", "township", "conurbation"],
  ["book", "volume", "tome", "publication", "title"],
  ["ship", "vessel", "boat", "freighter", "steamer"],
  ["doctor", "physician", "clinician", "medic", "practitioner"],
  ["film", "movie", "picture", "feature", "motion-picture"],
  ["plan", "scheme", "strategy", "blueprint", "roadmap"],
  ["teacher", "educator", "instructor", "tutor", "lecturer"],
  ["meeting", "gathering", "session", "assembly", "convocation"],
  ["money", "cash", "funds", "capital", "currency"],
];

// word -> index into CLUSTERS. Built once at module load; every lookup is O(1).
const CLUSTER_OF = new Map<string, number>();
CLUSTERS.forEach((group, i) => {
  for (const word of group) CLUSTER_OF.set(word, i);
});

// Singular lookup for a plural surface form ("the vehicles"). Nothing fancier: the table holds
// singulars, and stripping a trailing "s" (or "es") is enough to find them.
function clusterIndex(surface: string): number | undefined {
  const lc = surface.toLowerCase();
  const direct = CLUSTER_OF.get(lc);
  if (direct !== undefined) return direct;
  if (lc.endsWith("es")) {
    const stripped = CLUSTER_OF.get(lc.slice(0, -2));
    if (stripped !== undefined) return stripped;
  }
  return lc.endsWith("s") ? CLUSTER_OF.get(lc.slice(0, -1)) : undefined;
}

// --- occurrences ----------------------------------------------------------------------------------

type Occurrence = { cluster: number; noun: string; unitIndex: number; span: Span };

const isWordToken = (w: WordSpan): boolean => /[\p{L}\p{N}]/u.test(w.text);

// Every "<determiner> … <cluster noun>" phrase in the document, in order. The span runs from the
// determiner through the noun, so a finding slices back to the phrase the writer actually wrote.
function occurrences(doc: DocAnalysis): Occurrence[] {
  const out: Occurrence[] = [];
  doc.units.forEach((unit, unitIndex) => {
    const words = unit.words.filter(isWordToken);
    for (let i = 0; i < words.length; i++) {
      if (!DETERMINERS.has(words[i]!.text.toLowerCase())) continue;
      for (let j = i + 1; j <= i + 1 + MAX_GAP && j < words.length; j++) {
        const cluster = clusterIndex(words[j]!.text);
        if (cluster === undefined) continue;
        const noun = words[j]!.text.toLowerCase();
        out.push({ cluster, noun, unitIndex, span: spanning([words[i]!, words[j]!]) });
        i = j; // the noun is consumed; don't let it pair with a second determiner
        break;
      }
    }
  });
  return out;
}

// --- windows ---------------------------------------------------------------------------------------

type Cycle = { cluster: number; nouns: string[]; span: Span };

// The earliest qualifying window for one cluster, then the scan resumes past it — a run of five
// synonyms reads as one cycle, not three overlapping ones.
function cyclesIn(cluster: number, occs: readonly Occurrence[]): Cycle[] {
  const out: Cycle[] = [];
  let from = 0;
  while (from < occs.length) {
    const start = occs[from]!;
    const window = occs.slice(from).filter((o) => o.unitIndex - start.unitIndex < WINDOW);
    const counts = new Map<string, number>();
    for (const o of window) counts.set(o.noun, (counts.get(o.noun) ?? 0) + 1);
    const once = window.filter((o) => counts.get(o.noun) === 1);
    if (once.length >= MIN_DISTINCT) {
      out.push({ cluster, nouns: once.map((o) => o.noun), span: spanning(once) });
      from += window.length;
      continue;
    }
    from++;
  }
  return out;
}

export const elegantVariationRule: TropeRule = {
  id: RULE_ID,
  name: "Elegant variation (synonym-cycling for one referent)",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const byCluster = new Map<number, Occurrence[]>();
    for (const occ of occurrences(doc)) {
      const list = byCluster.get(occ.cluster);
      if (list) list.push(occ);
      else byCluster.set(occ.cluster, [occ]);
    }

    const cycles = [...byCluster.entries()]
      .flatMap(([cluster, occs]) => cyclesIn(cluster, occs))
      .sort((a, b) => a.span.start - b.span.start || a.span.end - b.span.end);

    const distinctClusters = new Set(cycles.map((c) => c.cluster)).size;
    const severity: Severity = distinctClusters >= 2 ? "medium" : "low";
    const density = distinctClusters >= 2 ? ` Two different things get this treatment in one piece, which makes it a habit rather than a slip.` : "";

    return cycles.map((c) => {
      const named = c.nouns.map((n) => `“${n}”`).join(", ");
      return {
        ruleId: RULE_ID,
        span: c.span,
        severity,
        message: `Elegant variation: ${c.nouns.length} names for one thing — ${named}`,
        explanation:
          `${named} all point at the same thing here, each used exactly once, within a few sentences of each other. ` +
          `Swapping in a synonym every time avoids a repeated word at the cost of the reader's certainty that it is still the same thing — ` +
          `they have to stop and check. Pick the plainest of the ${c.nouns.length} (“${c.nouns[0]}”), use it every time, and reach for a pronoun when the repetition gets heavy.` +
          density,
      };
    });
  },
};
