// IR — the semantic layer. What *roles* exist, not where pixels go.
// The constituency parse is lowered to this before any layout happens.

export type Word = {
  text: string;
  pos?: string; // Penn-Treebank POS tag from the parse (NN, JJ, RB, VBD…), when the word is a single leaf
};

// Head slots may be single or compound ("dogs and cats run"). A subject may also be a verbal or a
// whole clause used nominally ("Running marathons is fun", "Whoever made this did a good job"),
// drawn raised on a stand.
export type Subject = Nominal | Compound<Nominal> | Clause | Infinitive | Gerund;
// A compound predicate forks into parts, each carrying its OWN complement ("[has black fur] and
// [can jump high]") — a single clause-level complement can't hold per-conjunct objects.
export type PredicatePart = { verb: Verbal; complement: Complement | null };
export type Predicate = Verbal | Compound<PredicatePart>;

export type Clause = {
  subject: Subject;
  verb: Predicate;
  complement: Complement | null; // direct object, predicate noun/adj, or null (intransitive)
  detached?: Word[]; // interjections / nominatives of address — floating line above, unconnected
  absolutes?: Nominal[]; // absolute phrases ("Smoke alarms screaming, ...") — detached noun+participle above
};

export type Nominal = {
  head: Word;
  modifiers: Modifier[]; // hang below the head
  appositive?: Word; // drawn in parens on the baseline
};

export type Verbal = {
  head: Word; // may be a verb phrase ("has been running")
  modifiers: Modifier[];
  indirectObject?: Nominal; // hangs below on a slant + rail
};

// A verbal: a verb form used as another part of speech, with its own R-K notation.
// Infinitive ("to take a walk") sits on a stand. (Gerund/participle to follow.)
export type Infinitive = {
  kind: "infinitive";
  verb: Word; // "take"
  object: Nominal | null; // "a walk"
  modifiers: Modifier[]; // adverbs / PPs on the infinitive verb
};

// A gerund phrase ("Running marathons") used as a noun — verb + optional object + modifiers,
// drawn on a raised rail (on a stand when it fills a subject/object slot).
export type Gerund = {
  kind: "gerund";
  verb: Word; // "Running"
  object: Nominal | null; // "marathons"
  modifiers: Modifier[];
};

export type Complement =
  | { kind: "directObject"; value: Nominal | Compound<Nominal> | Infinitive | Clause } // half-vertical (Clause = a causative small clause on a stand)
  | { kind: "predicateNoun"; value: Nominal | Compound<Nominal> } // divider: lean-left
  | { kind: "predicateAdj"; value: Word | Compound<Word> } // divider: lean-left ("tiny and loud" -> fork)
  // objective complement ("elected my uncle mayor", "painted my room red"): the direct object,
  // then a back-leaning divider, then the complement noun/adjective — all on the baseline.
  | { kind: "objectComplement"; object: Nominal | Compound<Nominal>; oc: Nominal | Word; ocIsAdj: boolean };

export type Modifier =
  | { kind: "word"; value: Word } // adj/article/adverb/possessive -> slant
  | { kind: "prep"; prep: Word; object: Nominal } // slant carries prep, sub-rail carries object  (recursion)
  | { kind: "clause"; value: Clause; connector: Word } // relative/subordinate, dotted connection  (recursion)
  // participial phrase ("the dog barking furiously") -> the participle on a curved line under the
  // noun, carrying its own object and modifiers.
  | { kind: "participle"; verb: Word; object: Nominal | null; modifiers: Modifier[] };

// Compound wrapper (compound subject/predicate/object): fork + dotted conjunction line.
export type Compound<T> = { items: T[]; conjunction: Word };

// One or more clauses laid out together. conjunctions[i] joins clauses[i] and clauses[i+1]:
// a Word for a coordinated compound sentence ("Birds sing and dogs bark"), or null for two
// independent sentences stacked from split input ("A. B" / "A: B" — no connector drawn).
export type Sentence = { clauses: Clause[]; conjunctions: Array<Word | null> };
