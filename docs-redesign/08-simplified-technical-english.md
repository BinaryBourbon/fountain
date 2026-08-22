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

Three kinds of -ing word stay. A word the dictionary approves in its own right
(`during`, `string`, `warning`). A Technical Name (`billing`, `logging`,
`staging`). A code identifier, which is exempt because it is code.

### Words

Use the approved word. `vale lint --audit docs` reports every word the
wordset rejects, with a replacement for each. This table holds the ones that
came up most in these pages, and they are also the ones the linter is most
clearly right about.

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

The linter is [`stuffbucket/vale`](https://github.com/stuffbucket/vale), an MIT
pure-Go ASD-STE100 checker. It parses Markdown to an AST and lints prose nodes
only, so code, HTML, URLs and front matter are exempt by construction. It is
not certified by ASD and it does not bundle the licensed dictionary. It
approximates Part 1 from the MIT OpenSTE wordset.

CI installs it with `go install github.com/stuffbucket/vale/cmd/vale@v0.15.0`
and runs `vale lint docs` in the two jobs that already run
`scripts/docs-style.py`. Configuration is `.vale-ste.yml` at the repo root.

Locally, install it once and run it the same way.

```sh
go install github.com/stuffbucket/vale/cmd/vale@v0.15.0
vale lint docs                 # the gate
vale lint --audit docs         # the gate, plus the vocabulary advice
```

| Rule | Severity | Gated |
|---|---|---|
| `STE.SentenceLength` | error | yes |
| `STE.Contractions` | error | yes |
| `STE.PassiveVoice` | warning | yes |
| `STE.PhrasalVerbs` | warning | yes |
| `STE.OneInstruction` | warning | yes |
| `STE.IngForms` | warning, raised from suggestion | yes |
| `STE.Vocabulary` | suggestion | no |

`STE.Vocabulary` advises and does not gate. The wordset behind it was built for
aircraft maintenance, and part of what it says degrades software prose. It
wants "examine" in place of "search", "the two" in place of "both", and
"flush" in place of "running". Read it with `--audit` and take the words it is
right about. Those are the ones in the table above, and every general style
guide names them too.

Two rules in this page reach no checker at all. Noun clusters need a parser.
One word with one meaning needs the licensed dictionary. Both are the
reviewer's job.

### Technical Names

`vocabulary.allow` in `.vale-ste.yml` holds them. A word goes there when it
names a thing in this system or in one Fountain talks to. A word does not go
there to escape a rewrite.

### The ratchet

`.valeignore` is the backlog. A page listed there is skipped. A page not
listed is checked, so a page written tomorrow is covered from the day it
lands. The list only shrinks.

The backlog started at 76 pages, 219 errors and 343 warnings.

## What this does not claim

STE makes text readable. It does not make text true. Accuracy, completeness
and the choice of what to document are craft, and no rule in this page reaches
them.

It also costs something. The prose gets plainer, and a page that was pleasant
to read becomes a page that is quick to read. That is the trade, and for a
control plane that people self-host at three in the morning, it is the right
one.
