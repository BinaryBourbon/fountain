// POS tagger backed by `compromise` (pure-JS, ships in the bundle — no WASM, no model
// download). It replaced a hand-rolled lexicon+morphology tagger whose failures were all POS
// ambiguities a rule can't resolve ("sally" noun vs -ly adverb; "sold" verb vs unknown word).
//
// We map compromise's rich tag set down to the coarse tags the chunker (parse.ts) consumes.
// Open-class words stay "X" (the chunker assigns noun/adjective by position); a detected verb
// is marked forced:"V" so the chunker treats it as the predicate reliably.
//
// compromise also emits ZERO-WIDTH terms for the second half of a contraction; see the
// "contracted verbs" section below for which ones we put back and which stay dropped.
//
// ENGLISH-SPECIFIC: this + parse.ts + lower.ts are the English layer. A future multilingual
// path swaps in a Universal-Dependencies parser and a dependency->IR lowering; the IR and
// everything downstream are unchanged.

import nlp from "compromise";
import { POSS, AUX, SUBORD, REL, ADV } from "./lexicon.js";

export type Tag = "DT" | "PRP$" | "PRP" | "IN" | "TO" | "SUB" | "REL" | "CC" | "MD" | "COP" | "AUX" | "RB" | "CD" | "JJ" | "X" | "," | ".";
// `comma`: this word is followed by a comma. compromise carries punctuation in a term's trailing
// whitespace rather than as a term of its own, so without this the chunker cannot see where a
// phrase was set off — which is the only signal distinguishing a trailing participial phrase
// ("opened in 1994, highlighting ...") from a verb chain ("kept highlighting ...").
export type Tagged = { word: string; lc: string; tag: Tag; forced?: "V"; comma?: true };

type Term = { text: string; tags?: string[]; post?: string };

function mapTags(word: string, tags: Set<string>): { tag: Tag; forced?: "V" } {
  const lc = word.toLowerCase();
  if (/^[.!?;:]$/.test(word)) return { tag: "." };
  if (word === ",") return { tag: "," };
  if (lc === "to") return { tag: "TO" }; // infinitive marker OR preposition — disambiguated in the chunker
  if (POSS.has(lc)) return { tag: "PRP$" };
  if (SUBORD.has(lc)) return { tag: "SUB" };
  if (AUX.has(lc)) return { tag: "AUX" };
  if (REL.has(lc) && !tags.has("Determiner")) return { tag: "REL" };
  if (tags.has("Determiner")) return { tag: "DT" };
  if (tags.has("Modal")) return { tag: "MD" };
  if (tags.has("Copula")) return { tag: "COP" };
  if (tags.has("Conjunction")) return { tag: "CC" };
  if (tags.has("Pronoun")) return { tag: "PRP" };
  if (tags.has("Preposition")) return { tag: "IN" };
  if (tags.has("Adverb") || tags.has("Negative") || ADV.has(lc)) return { tag: "RB" }; // incl. "not"
  if (tags.has("Value") || tags.has("Cardinal")) return { tag: "CD" };
  if (tags.has("Verb")) return { tag: "X", forced: "V" }; // open-class verb -> the predicate
  if (tags.has("Adjective")) return { tag: "JJ" };
  return { tag: "X" }; // noun / unknown -> resolved by position in the chunker
}

// --- contracted verbs ---
//
// compromise splits a contraction into the host word plus a ZERO-WIDTH term carrying the clitic's
// tags: "It's not bold" arrives as ["It's" Pronoun, "" Verb+Copula, "not" Negative, "bold"
// Adjective]. Dropping the empty term (what this file used to do) threw away the sentence's only
// verb, so the chunker saw PRP RB JJ and readDocument called the whole thing a fragment (#31).
//
// We restore it by splitting the clitic off the host and expanding it to the full form the rest of
// the pipeline already keys on — lower.ts's COPULA list and lint/ir-query's BE_FORMS both hold
// "is"/"are"/"am", never "'s" — so "It's" tags as It/PRP is/COP. Expanding also matches how a
// contraction is conventionally diagrammed (the verb goes on the baseline in full).
const CLITIC = /['’](s|re|m|ve|ll|d)$/i;

// Which verb the clitic stands for. compromise's own tags on the zero-width term disambiguate the
// two ambiguous ones: "'s" is the copula ("It's bold") unless it is a bare auxiliary ("It's been
// raining" -> has), and "'d" is "would" when tagged Modal ("She'd like tea") and "had" otherwise
// ("She'd left already").
function expandClitic(clitic: string, tags: Set<string>): string | null {
  switch (clitic) {
    case "s": return tags.has("Copula") ? "is" : tags.has("Auxiliary") ? "has" : null;
    case "re": return "are";
    case "m": return "am";
    case "ve": return "have";
    case "ll": return "will";
    case "d": return tags.has("Modal") ? "would" : "had";
    default: return null;
  }
}

export function tag(text: string): Tagged[] {
  // compromise's published types don't expose the runtime json() options shape; cast past it.
  const sentences = (nlp(text) as { json(o: unknown): unknown }).json({ terms: true }) as Array<{ terms: Term[] }>;
  const out: Tagged[] = [];
  let prevTags = new Set<string>(); // tags of the term that produced out[out.length - 1]
  const push = (word: string, tags: Set<string>): void => {
    const m = mapTags(word, tags);
    out.push(m.forced ? { word, lc: word.toLowerCase(), tag: m.tag, forced: m.forced } : { word, lc: word.toLowerCase(), tag: m.tag });
  };
  // compromise keeps a comma in the preceding term's trailing whitespace, so record it on the word
  // it follows (see Tagged.comma).
  const markComma = (): void => {
    const last = out[out.length - 1];
    if (last) last.comma = true;
  };
  for (const sent of sentences) {
    for (const t of sent.terms) {
      const tags = new Set(t.tags ?? []);
      const word = t.text;
      if (!word) {
        // Only a VERB clitic is restored. A zero-width Negative ("isn't" -> "isn't" + "") stays
        // dropped on purpose: the negation is still visible in the surface word, and downstream
        // (lint/ir-query's stripContractedNegation) reads it off the fused verb head. A zero-width
        // pronoun ("Let's" -> "Let" + "us") is left alone too — splitting it would turn an
        // imperative into a subject the chunker would then have to re-analyse.
        const prev = out[out.length - 1];
        const m = prev && tags.has("Verb") ? CLITIC.exec(prev.word) : null;
        const full = m && m.index > 0 ? expandClitic(m[1]!.toLowerCase(), tags) : null;
        if (!m || !full || !prev) continue;
        out.pop();
        push(prev.word.slice(0, m.index), prevTags); // host word without the clitic, re-tagged
        push(full, tags);
        prevTags = tags;
        if (t.post?.includes(",")) markComma();
        continue;
      }
      push(word, tags);
      prevTags = tags;
      if (t.post?.includes(",")) markComma();
    }
  }
  return out;
}
