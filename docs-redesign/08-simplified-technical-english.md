# Deliverable 8: Simplified Technical English

Every published page under `docs/` is written in ASD-STE100 Simplified
Technical English. This page says what that means here, what it does not mean,
and which part of it CI enforces.

Deliverable 4 (`06-voice-and-style.md`) is not replaced. Its three named rules
survive unchanged, and STE agrees with all three. STE goes further, and where
the two differ, STE wins.

## What ASD-STE100 is

ASD-STE100 is a controlled English specification. The aerospace industry wrote
it so that a technician whose first language is not English can read a
maintenance manual once and act on it. It has two halves.

**Part 1 is a dictionary.** About 900 approved words. Each word has one
meaning and one part of speech. "Follow" means "to come after". It does not
also mean "to obey". A word outside the dictionary is not usable unless it is
a Technical Name or a Technical Verb.

**Part 2 is 65 writing rules.** They cover sentence length, the passive voice,
the -ing form, articles, noun clusters, paragraphs, warnings and procedures.

The dictionary is licensed and is not in this repository. Part 2 is what the
checker enforces, plus a short list of the not-approved words this repository
used most.

## Why this documentation uses it

Three reasons, in order of weight.

The readers are not all native speakers of English. Fountain is an open source
control plane, and the people who self-host it read the operations guides
under time pressure and in a second language.

The pages are procedural. A guide that says "put it on the internet" or "run a
release task" is a maintenance manual. STE was designed for exactly this text.

The rules make vagueness visible. A 40-word sentence with a trailing clause
hides a claim that nobody checked against the code. STE breaks the sentence,
and the claim then stands alone and is either true or false.

## The rules, as they apply here

### Sentences

A procedural sentence takes 20 words or fewer. A descriptive sentence takes 25
words or fewer. Write one instruction in one sentence. Two instructions take
two sentences, or two numbered steps.

A paragraph of descriptive text takes 6 sentences or fewer. A paragraph of
procedural text takes one step.

Keep to one topic in one paragraph.

### The active voice

Use the active voice in every procedure. Rule 3.2 makes this absolute.

Use the active voice in description also. Rule 3.3 lets you write the passive
when the actor is unknown or does not matter, but that case is rare in this
documentation. Fountain, the sandbox, the runtime, the operator and the reader
are all named actors.

| Passive | Active |
|---|---|
| The secrets are merged at spawn time. | Fountain merges the secrets at spawn time. |
| The conversation is marked failed. | The reaper marks the conversation failed. |
| A token is issued by the API. | The API issues a token. |

### The -ing form

Do not write the present participle. Do not write the gerund. Rule 3.4 rejects
both, because a reader who is learning English cannot tell which of the two a
sentence uses, and the two mean different things.

| Not this | This |
|---|---|
| A running conversation holds a sandbox. | A conversation that runs holds a sandbox. |
| Running an instance needs a database. | An instance needs a database to run. |
| Fountain merges the maps, giving the Vault priority. | Fountain merges the maps. The Vault wins. |
| The existing sandbox wakes. | The sandbox that is already there wakes. |

Three -ing words stay. A word the dictionary approves in its own right
(`during`, `string`, `warning`). A Technical Name (`billing`, `logging`,
`staging`). A code identifier, which is exempt because it is code.

`ING_ALLOWED` in `scripts/docs-ste.py` holds both lists. Add a word to it only
when the word names a thing. Do not add a word to escape a rewrite.

### Words

Use the approved word. The checker holds the not-approved words this
documentation used, with the approved word for each.

| Not approved | Write |
|---|---|
| via | through, with, by |
| require | need |
| provide | give |
| perform | do |
| utilize | use |
| prior to | before |
| in order to | to |
| however | but |
| additional | more |
| may | can, or must |
| allow | let |
| execute | run |
| indicate | show |
| ensure | make sure |

`may` deserves its own note. STE removed it because it carries permission and
possibility at once. Decide which one you mean. "The Vault can hold a secret"
is possibility. "You must set `MASTER_SECRETS_KEY`" is obligation.

Write "do not", not "don't". Write "it is", not "it's".

### Noun clusters

Three nouns in a row is the limit. `sandbox provider contract` is three and is
allowed. `sandbox provider capability contract` is four. Break it with a
preposition. Write `the capability contract for a sandbox provider`.

The checker does not test this rule, because it cannot tell a noun from a verb
without a parser. A reviewer can.

### One word, one meaning

This is Part 1's core idea, and Deliverable 4 already fixed the five words
Fountain overloads. That table in `06-voice-and-style.md` is the local
dictionary. It stands.

Two additions that come from STE rather than from the overload audit.

**"Follow" means "to come after".** Write "read the guide", not "follow the
guide". Write "obey the rule", not "follow the rule".

**"Fine" means nothing here.** So do "clean", "happy" and "healthy" as
adjectives for a process. Write what the process does.

### Warnings and cautions

Put the warning before the step it applies to, never after. Write it as a
command.

> Do not run `mix ecto.reset` against production. The command drops the
> database.

## What STE does not touch

**Code.** A fenced block, an indented block and an inline span all quote the
world. STE has no opinion on `SPRITES_TOKEN` or on a shell pipeline.

**Real output.** Deliverable 4 says paste real output including ids. That
still holds. Output is a quotation.

**Identifiers in prose.** `assert_active!/1` keeps its name. A Technical Name
is a Technical Name whatever shape it has.

**Third-party names.** Sprites, E2B, Daytona, HashiCorp Vault, Stripe.

**The changelog.** `docs/changelog.md` includes `CHANGELOG.md`, which is a
record of what happened and is not rewritten after the fact.

## What CI enforces

`scripts/docs-ste.py`, in the same two CI jobs that run
`scripts/docs-style.py`. Six rules.

1. Sentence length, 20 words procedural and 25 descriptive.
2. Paragraph length, 6 sentences.
3. The not-approved word list.
4. Contractions.
5. The passive voice, by a be-verb and participle heuristic.
6. The -ing form, against `ING_ALLOWED`.

Two rules in this page are for a human reviewer and not for CI. Noun clusters
need a parser. One word with one meaning needs the licensed dictionary.

### The ratchet

`scripts/docs-ste-allow.txt` is the backlog. A file on it is skipped. A file
not on it is checked, so a new page is covered from the day somebody writes
it. The list only shrinks, and the checker fails if a line names a file that
no longer exists.

The backlog started at 75 files and 1,659 findings.

### The per-line escape

A line that ends with `<!-- ste-ok -->` is skipped. It exists for a quotation
of somebody else's words, and for the passive that Rule 3.3 permits because no
actor exists to name. The run prints how many are in use. Treat a rise in that
number the way you would treat a line added to the backlog.

## What this does not claim

STE makes text readable. It does not make text true. Accuracy, completeness
and the choice of what to document are craft, and no rule in this page reaches
them.

It also costs something. The prose gets plainer, and a page that was pleasant
to read becomes a page that is quick to read. That is the trade, and for a
control plane that people self-host at three in the morning, it is the right
one.
