// Dead-metaphor candidates (discourse tier, issue #22) — a rare CONTENT lemma recurring far above
// its expected rate: "walls and doors" repeated thirty times until the figure of speech has worn
// through to a tic, or any image/metaphor reused as a crutch rather than developed once and left
// alone.
//
// No corpus is available at runtime, so there's no real background frequency to compare a word
// against. Two document-internal proxies stand in for it:
//
//   1. "content word" = not a function word. STOPWORDS below is a small, closed, hand-picked list
//      of English function words — pronouns, articles, prepositions, conjunctions, auxiliaries,
//      negation, degree words (~130 entries).
//   2. "rare" = absent from COMMON_WORDS, a hand-assembled list of ~300 everyday English content
//      words ("time", "people", "world", "make", "know", "day"...) modeled loosely on the shape
//      of a top-1000-word frequency list but built by hand for this file, not exported from a
//      real corpus — there is no such table available in the browser build. A word that ISN'T on
//      this list is "rare" only in this coarse, document-internal sense: it might be a genuine
//      technical term (fine, expected to repeat) or a word the list simply omits. The rule can't
//      tell those apart on its own — see the tuning note below for how thresholds compensate.
//
// Deliberately absent from COMMON_WORDS: "wall", "door", and comparably-common but non-essential
// nouns. They're frequent enough in general English that a genuinely exhaustive top-1000 list
// would include them and this rule could never flag the issue's own example. Keeping the list
// modest, by hand, is a design choice, not an oversight.
//
// Tuning against the must-not-fire case (a technical doc repeating "the parser" once per distinct
// sentence): the absolute floor BASE_MIN_COUNT and the doc-relative RATE_THRESHOLD below are both
// picked so a handful of ordinary term mentions across a short document never qualifies — see
// dead-metaphor.test.ts for the worked numbers.

import type { DocAnalysis, Finding, Severity, Span, TropeRule } from "../types.js";

// --- data: function words (excluded from "content word" entirely) ---------------------------

const STOPWORDS = new Set([
  "a", "an", "the",
  "i", "me", "my", "mine", "myself", "you", "your", "yours", "yourself", "yourselves",
  "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself",
  "we", "us", "our", "ours", "ourselves", "they", "them", "their", "theirs", "themselves",
  "this", "that", "these", "those",
  "who", "whom", "whose", "which", "what", "whatever", "whichever", "whoever",
  "and", "or", "but", "nor", "so", "yet", "if", "because", "although", "though", "while", "as",
  "than", "whether", "unless", "until", "since",
  "in", "on", "at", "by", "for", "with", "about", "against", "between", "into", "through",
  "during", "before", "after", "above", "below", "to", "from", "up", "down", "over", "under",
  "again", "further", "once", "of", "off", "out",
  "be", "am", "is", "are", "was", "were", "been", "being",
  "have", "has", "had", "having",
  "do", "does", "did", "doing",
  "will", "would", "shall", "should", "may", "might", "must", "can", "could",
  "not", "no", "nor",
  "there", "here",
  "very", "too", "also", "just", "only", "even", "still", "then",
  "all", "any", "some", "each", "every", "other", "another", "such", "own", "same",
  "etc",
]);

// --- data: common English content words (excluded because they're too ordinary to be "rare") -
// Hand-assembled for this rule, not sourced from a frequency corpus (none is available at
// runtime). Roughly 300 entries, biased toward the everyday nouns/verbs/adjectives that dominate
// ordinary prose, so their repetition is expected rather than a metaphor tic.
const COMMON_WORDS = new Set([
  "time", "people", "way", "day", "man", "woman", "thing", "life", "child", "world", "school",
  "state", "family", "student", "group", "country", "problem", "hand", "part", "place", "case",
  "week", "company", "system", "program", "question", "work", "government", "number", "night",
  "point", "home", "water", "room", "mother", "area", "money", "story", "fact", "month", "lot",
  "study", "book", "eye", "job", "word", "business", "issue", "side", "kind", "head", "house",
  "service", "friend", "father", "power", "hour", "game", "line", "end", "member", "law", "car",
  "city", "community", "name", "president", "team", "minute", "idea", "body", "information",
  "back", "parent", "face", "level", "office", "health", "person", "art", "history", "party",
  "result", "change", "morning", "reason", "research", "girl", "guy", "moment", "air", "teacher",
  "force", "education", "foot", "boy", "age", "policy", "process", "music", "market", "sense",
  "nation", "plan", "college", "interest", "death", "experience", "effect", "use", "class",
  "control", "care", "field", "development", "role", "effort", "rate", "heart", "show", "leader",
  "light", "voice", "wife", "whole", "mind", "price", "report", "decision", "son", "hope", "view",
  "relationship", "town", "road", "arm", "election", "hair", "situation", "step", "culture",
  "model", "writer", "offer", "chance", "order", "forward", "half", "sea", "plane", "mission",
  "product", "standard", "project", "sound", "base", "star", "ready", "focus", "action",
  "movement", "note", "court", "industry", "agency", "style", "evening", "matter", "choice",
  "cause", "opinion", "top", "region", "table", "wind", "event", "army", "mouth", "tax",
  "structure", "feeling", "unit", "food", "cell", "difference", "agreement", "front", "board",
  "activity", "energy", "budget", "condition", "media", "network", "security", "individual",
  "animal", "series", "million", "official", "staff", "discussion", "average", "environment",
  "majority", "income", "phone", "blood", "sort", "wood", "image", "weight", "task", "category",
  "quality", "statement", "technology", "worker", "benefit", "position", "sample", "exercise",
  "factor", "letter", "master", "machine", "entire", "source", "memory", "size", "past",
  "evidence", "tree", "entry", "patient", "generation", "thought", "capital", "video", "character",
  "page", "resource", "wave", "band", "term", "oil", "revenue", "gene", "sky", "fish", "respect",
  "purpose", "section", "growth", "guest", "tone", "horse", "dog", "cat", "bird", "flower",
  "river", "mountain", "forest", "ocean", "beach", "storm", "cloud", "rain", "snow", "sun", "moon",
  "make", "know", "think", "take", "come", "give", "look", "find", "tell", "ask", "seem", "feel",
  "leave", "call", "need", "want", "become", "put", "mean", "keep", "let", "begin", "help", "talk",
  "turn", "start", "show", "hear", "play", "run", "move", "live", "believe", "bring", "happen",
  "write", "sit", "stand", "lose", "pay", "meet", "include", "continue", "set", "learn", "change",
  "lead", "understand", "watch", "follow", "stop", "create", "speak", "read", "allow", "add",
  "spend", "grow", "open", "walk", "win", "offer", "remember", "consider", "appear", "buy", "wait",
  "serve", "die", "send", "expect", "build", "stay", "fall", "cut", "reach", "kill", "remain",
  "good", "new", "first", "last", "long", "great", "little", "own", "other", "old", "right",
  "big", "high", "different", "small", "large", "next", "early", "young", "important", "few",
  "public", "bad", "same", "able", "human", "local", "sure", "possible", "hard", "clear", "true",
]);

const MIN_WORD_LEN = 4; // below this, even a "rare" token is too short to read as a content word

// --- data: a light, document-internal lemmatizer (heuristic, not linguistic) -----------------
// Collapses common English inflections so "wall"/"walls" and "door"/"doors" count together. It's
// suffix-stripping, not a dictionary lemmatizer — good enough to group inflections of the SAME
// word within one document, not meant to be linguistically exact (see the false negative on
// "trees" vs "tree" that the tests document and accept).
function lemmatize(lower: string): string {
  if (lower.length <= 3) return lower;
  if (/[^aeiou]ies$/.test(lower)) return `${lower.slice(0, -3)}y`; // parties -> party
  if (/(sses|shes|ches|xes|zes)$/.test(lower)) return lower.slice(0, -2); // boxes -> box
  if (/[^aeiou]s$/.test(lower)) return lower.slice(0, -1); // walls -> wall, doors -> door
  if (/[^aeiou]ing$/.test(lower) && lower.length > 5) return lower.slice(0, -3); // walking -> walk
  if (/[^aeiou]ed$/.test(lower) && lower.length > 4) return lower.slice(0, -2); // walked -> walk
  return lower;
}

// --- thresholds --------------------------------------------------------------------------------
// Below this many qualifying content words, per-lemma rate is too noisy to trust at all (a
// five-sentence document "repeating" a word 3 times is unremarkable).
const MIN_DOC_CONTENT_WORDS = 40;
// Absolute floor: fewer than this many repeats of one lemma is unremarkable regardless of
// document size — this is what keeps a short technical doc's handful of "parser" mentions clean.
const BASE_MIN_COUNT = 10;
// Doc-relative floor: a lemma eating more than 4% of ALL content-word tokens is disproportionate
// even in a long document, where the absolute floor alone would be too lax.
const RATE_THRESHOLD = 0.04;
const TOP_K = 8; // report at most this many candidate lemmas, worst rate first

type LemmaGroup = { lemma: string; count: number; surfaceForms: Set<string>; firstSpan: Span };

export const deadMetaphorRule: TropeRule = {
  id: "dead-metaphor/rare-lemma",
  name: "Dead-metaphor candidate",
  tier: "discourse",
  detect(doc: DocAnalysis): Finding[] {
    const groups = new Map<string, LemmaGroup>();
    let contentWordCount = 0;

    for (const unit of doc.units) {
      for (const w of unit.words) {
        const lc = w.text.toLowerCase();
        if (lc.length < MIN_WORD_LEN || STOPWORDS.has(lc)) continue;
        // Check the common-words list against both the surface form and its lemma: "shows"
        // isn't itself in COMMON_WORDS, but its lemma "show" is, and an inflected common verb is
        // exactly as ordinary as its base form.
        const lemma = lemmatize(lc);
        if (COMMON_WORDS.has(lc) || COMMON_WORDS.has(lemma)) continue;
        contentWordCount++;
        const existing = groups.get(lemma);
        if (existing) {
          existing.count++;
          existing.surfaceForms.add(lc);
        } else {
          groups.set(lemma, { lemma, count: 1, surfaceForms: new Set([lc]), firstSpan: w.span });
        }
      }
    }

    if (contentWordCount < MIN_DOC_CONTENT_WORDS) return [];

    const minCount = Math.max(BASE_MIN_COUNT, Math.ceil(contentWordCount * RATE_THRESHOLD));

    const candidates = [...groups.values()]
      .filter((g) => g.count >= minCount)
      .sort((a, b) => b.count - a.count || (a.lemma < b.lemma ? -1 : 1))
      .slice(0, TOP_K);

    return candidates.map((g): Finding => {
      const severity: Severity = g.count >= minCount * 3 ? "high" : g.count >= minCount * 1.5 ? "medium" : "low";
      const forms = [...g.surfaceForms].sort().join("/");
      const rate = Math.round((g.count / contentWordCount) * 100);
      return {
        ruleId: "dead-metaphor/rare-lemma",
        span: g.firstSpan,
        severity,
        message: `“${forms}” recurs ${g.count} times (${rate}% of the document's content words)`,
        explanation: `“${forms}” isn't a common English word, so ${g.count} occurrences — against a floor of ${minCount} for a document this size — is disproportionate for one piece of writing. That's the shape of a metaphor or image reused as a crutch rather than developed once and left alone: if it's figurative, cut most of the repeats; if it's a genuine technical term, still vary it with a pronoun or a synonym here and there.`,
      };
    });
  },
};
