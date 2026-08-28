// Function-word lexicon for the in-browser rule-based parser. Closed-class words (determiners,
// prepositions, pronouns, conjunctions, auxiliaries, subordinators) are finite and high-value:
// tagging them reliably is most of what a shallow parser needs. Open-class words (nouns, verbs,
// adjectives) are left ambiguous here and resolved by position in the chunker (parse.ts).

export const DET = new Set(["the", "a", "an", "this", "that", "these", "those", "each", "every", "some", "any", "no", "all", "both"]);
export const POSS = new Set(["my", "your", "his", "her", "its", "our", "their", "whose"]);
export const PRON = new Set(["i", "you", "he", "she", "it", "we", "they", "me", "him", "them", "us", "who", "what"]);
export const PREP = new Set([
  "in", "on", "at", "by", "for", "with", "from", "of", "about", "under", "over", "into", "onto",
  "through", "across", "behind", "beside", "between", "near", "toward", "towards", "against",
  "around", "above", "below", "during", "without", "within", "upon",
]);
export const SUBORD = new Set(["because", "although", "though", "while", "when", "whenever", "if", "unless", "since", "whereas", "as", "after", "before", "until"]);
export const REL = new Set(["that", "which", "who", "whom"]); // relative pronouns (clause introducers)
export const CONJ = new Set(["and", "or", "but", "nor"]);
export const MODAL = new Set(["will", "would", "can", "could", "shall", "should", "may", "might", "must"]);
export const COPULA = new Set(["is", "are", "am", "was", "were", "be", "been", "being", "seem", "seems", "seemed", "become", "becomes", "became", "feel", "feels", "felt", "look", "looks", "appear", "appears", "remain", "remains"]);
export const AUX = new Set(["has", "have", "had", "do", "does", "did"]);

// Common adverbs that don't end in -ly (the -ly ones are caught morphologically).
export const ADV = new Set(["not", "very", "here", "there", "now", "then", "today", "always", "never", "often", "soon", "again", "too", "also", "still", "just", "well", "fast", "almost", "quite", "so"]);

// A seed verb lexicon (base + common irregular forms) so verb detection doesn't rely on
// morphology alone. Not exhaustive — the chunker also uses -s/-ed/-ing and position.
export const VERBS = new Set([
  "run", "runs", "ran", "chase", "chases", "chased", "see", "sees", "saw", "seen", "eat", "eats", "ate", "eaten",
  "sleep", "sleeps", "slept", "bark", "barks", "barked", "like", "likes", "liked", "love", "loves", "loved",
  "go", "goes", "went", "make", "makes", "made", "take", "takes", "took", "give", "gives", "gave", "find", "finds", "found",
  "know", "knows", "knew", "think", "thinks", "thought", "say", "says", "said", "tell", "tells", "told", "want", "wants", "wanted",
  "play", "plays", "played", "read", "reads", "write", "writes", "wrote", "walk", "walks", "walked", "jump", "jumps", "jumped",
  "sit", "sits", "sat", "stand", "stands", "stood", "hold", "holds", "held", "bring", "brings", "brought", "build", "builds", "built",
  "catch", "catches", "caught", "throw", "throws", "threw", "hit", "hits", "won", "win", "wins", "drink", "drinks", "drank",
  // common irregular past / participle forms that don't end in -ed
  "sold", "sang", "sung", "swam", "drove", "rode", "spoke", "broke", "chose", "froze", "stole", "woke", "drew", "flew", "grew", "blew",
  "bought", "taught", "fought", "sought", "lost", "sent", "spent", "kept", "felt", "left", "meant", "dealt", "began", "rang", "sank",
  "became", "got", "forgot", "hung", "dug", "wore", "tore", "swore", "bore", "rose", "lit", "bit", "hid", "slid", "fell",
  "met", "fed", "led", "paid", "laid", "understood", "arose", "awoke", "shook", "rang",
]);

export const isNumber = (w: string) => /^\d[\d,.]*$/.test(w);
export const isCapitalized = (w: string) => /^[A-Z][a-z]/.test(w);
