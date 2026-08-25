# Deliverable 4: voice and style

One page. Every rule is enforceable by a reader with the text in front of them,
and most are enforceable by CI.

## The register, chosen deliberately

Fly.io and Modal sit at opposite ends of a range and both work.
`fly.io/docs/machines/overview/` contains "you don't need to be picky!", "in a
fiddly way", and a numbered list whose step 3 ends "if you want to do that,
GOTO 2". `modal.com/docs/guide` is terse and claim-then-stop with one joke per
page.

**Take Modal's calibration and Tailscale's honesty. Reject Fly's register.**
The reason is not taste. Fountain's audience is infrastructure-literate
developers with no prior model for a managed agent control plane, and the
jokes cost reading budget the reader needs for the model. Fly can afford them
because every reader already knows what a VM is.

**Take Fly's split, which is the part that matters.** Voice lives in
explanation only. Reference gets none. Fly's own site proves the split works,
because `/docs/machines/overview/` and `/docs/flyctl/machine-run/` are written
by the same organisation in two registers and both are correct.

| Mode | Register |
|---|---|
| Tutorial | First person plural, warm, confident. "We will create an agent." |
| How-to | Second person, imperative, no adjectives. "Set `SPRITES_TOKEN`." |
| Reference | No person. Declarative statements about the machinery. |
| Explanation | First person plural, allowed opinion, signed and dated. |

---

## The three named rules

### 1. No em dashes

Not `—`, not `–`, not ` - ` used as one.

The current docs contain **682 em dashes across 32 of 34 files**. `api.md` has
61, `architecture.md` 32, `primitives.md` 12.

The reason is not typographic preference. An em dash is a hinge that lets a
sentence continue after it has finished, and it is where Fountain's explanation
has been hiding. `primitives.md` reads "`runtime` — one of `claude`, `codex`,
`gemini`, `opencode`", where the dash stands in for a verb nobody chose.
Removing the dash forces the choice, and the choice is usually a table cell or
a new sentence.

Replace with one of four things.

| Was | Becomes |
|---|---|
| A definition after a term | A table row, or a colon-free sentence |
| A parenthetical aside | Parentheses, or a separate sentence |
| A pause before a conclusion | A full stop |
| A list gloss | A sub-bullet |

Before.

> The system prompt is written into the runtime's user-level instructions file
> on the agent's computer at provision and again at every reattach
> (`~/.claude/CLAUDE.md`, ...) — so an edit reaches an existing computer the
> next time it wakes

After.

> The system prompt is written into the runtime's user-level instructions file
> at provision and again at every reattach. An edit therefore reaches an
> existing computer the next time it wakes.

CI check. `grep -n '—\|–' docs/` returns nothing.

### 2. Colons do not introduce lists

The list's lead-in ends with a full stop.

The current docs use colon-introduced lists as the default construction. 19 in
`primitives.md`, 12 in `api.md`, 10 in `cli.md`, 8 in `architecture.md`.

The reason is that a colon makes the lead-in a fragment, and a fragment cannot
be wrong. "An Environment is a named, reusable baseline for a coding agent:"
asserts nothing that can be checked. Ending it with a full stop forces a
complete claim, and the claim is then either true or false against the code.

Before.

> An **Environment** is a named, reusable baseline for a coding agent:
>
> - Encrypted secrets ...
> - Plain env vars ...

After.

> An Environment holds four kinds of thing.
>
> - Encrypted secrets ...
> - Plain env vars ...

The count in the lead-in is a free correctness check. If the list grows to five
and the sentence still says four, the diff is visibly wrong.

Colons remain correct in three places. Inside code, in YAML and JSON, and after
a label in a definition list or admonition title.

CI check. No line matching `:$` immediately followed by a line starting `- ` or
`1. ` or `|`, outside fenced blocks.

### 3. A sentence states a claim and stops

No trailing explanatory clause. If the explanation matters, it is the next
sentence. If it does not matter, it is deleted.

This is the rule that actually changes the docs, and it is the one the other
two exist to enforce, because em dashes and colons are how trailing clauses
attach.

Before, from `primitives.md`, one 60-word sentence.

> A provider outside that set is rejected at write time: there is no credential
> for it, so the sandbox would have started with no inference key at all. The
> model id itself is *not* checked against a list — the agent form suggests
> current models, but anything you type is passed to the CLI as-is, so a model
> released since your Fountain version still works.

After, five sentences, same facts, no dashes, no colons.

> A provider outside that set is rejected at write time. Fountain holds no
> credential for it, so the sandbox would start with no inference key.
>
> The model id itself is not checked against a list. The agent form suggests
> current models, and anything you type is passed to the CLI unchanged. A model
> released after your Fountain version still works.

Three consequences worth naming, because writers resist this rule.

- Sentences get shorter and the paragraph gets longer. That is the trade, and
  it is the right one for a reader building a model.
- Causal words move to the front of their own sentence. "so", "because" and
  "which means" start sentences now.
- Some clauses turn out to have been carrying nothing. Delete those.

Diátaxis makes the same point from the other end. `diataxis.fr/reference/`
calls neutral description "the hardest thing to do" precisely because
explaining and opining are the natural way to write, and a trailing clause is
where both leak in.

---

## Rules that follow from the templates

**Verb-first how-to titles.** "Rotate the master secrets key", never "Key
rotation" and never "Rotating keys". `diataxis.fr/how-to-guides/` grades the
three forms explicitly and the bare noun phrase is "very bad".

**Explanation titles take an implicit "about".** "Where a secret comes from",
"Why you bring your own inference credentials". Never a verb.

**Reference titles are identifiers.** "Conversation states", not
"Understanding conversation states".

**State the mode in the first two sentences and link the twin.** Modal's
`modal.com/docs/guide/sandbox` does it in two sentences and it is the cheapest
structural fix available.

**State defaults with their override in the same place.** Value, unit,
ceiling, exact parameter. Modal's version is "a default maximum lifetime of 5
minutes. You can change this by passing a timeout of up to 24 hours to the
`Sandbox.create(...)` function."

**Paste real output, including ids.** Fly pastes a real machine id and a raw
IPv6 address in `/docs/machines/overview/`. Invented output teaches readers to
distrust output.

**Concede the failure case in the same breath as the feature.** Tailscale
introduces its relay fallback immediately after admitting "some especially
cruel networks block UDP entirely".

**Never describe unbuilt behavior as existing.** Already the repo's rule in
`CLAUDE.md`, and currently violated by the "MCP server (coming soon)" config
block on `llm-integration.md`.

---

## Terminology, fixed

Fountain overloads five terms. Pick one meaning each, use it everywhere, and
put the collisions in `reference/glossary.md`.

| Term | Means, in docs | Never means |
|---|---|---|
| Environment | the primitive | a deployment tier, or a map of env vars |
| environment variables | the values in a process | the Environment primitive |
| deployment | dev, staging, production | anything else |
| Agent | the primitive, the stored config | the running process |
| runtime | the coding-agent CLI (`claude`, `codex`, `gemini`, `opencode`) | |
| Conversation | the primitive, one run | the transcript |
| sandbox | the isolated machine a conversation runs in | |
| computer | nothing. Do not use it | the sandbox |
| Sprites, E2B, Daytona, runner | the four sandbox providers by name | a generic sandbox |
| Fountain | the product | the CLI binary, or the injected skill |
| `fountain` | the CLI binary, always in code font | |
| the `fountain` skill | the skill injected into every sandbox, always with "skill" | |

"Computer" is currently used throughout the team documentation for the sandbox
and is defined nowhere. It is a friendly word in a product surface and a
liability in reference. Delete it from docs and keep it in the UI if it earns
its place there.

## The Vault rule

Because of HashiCorp, the word "vault" carries a prior that inverts Fountain's
meaning. `developer.hashicorp.com/vault/docs/what-is-vault` establishes Vault
as the singular, central, authoritative store of dynamic leased credentials.
Fountain's Vault is a plural, small, static override layer that wins over the
Environment.

**Every page that introduces a Fountain Vault for the first time states the
collision before it states the feature.** The wording is worked in deliverable
5. Never write "Vault" unqualified in a heading where a newcomer meets it
first.

---

## What CI can enforce today

A `scripts/docs-style.sh` running on `docs/**/*.md`, outside fenced blocks.

1. No `—` or `–`.
2. No line ending in `:` immediately followed by a list item.
3. No sentence longer than 40 words. A warning, not a failure. It catches the
   trailing-clause rule without trying to parse grammar.
4. Every `docs/**/*.md` has a `mode:` key in its front matter, one of
   `tutorial`, `how-to`, `reference`, `explanation`, `hub`, `catalog-entry`.
5. Every page whose `mode:` is `catalog-entry` carries the full front matter
   set from deliverable 3.
6. Forbidden word list. "computer" outside code, "simply", "just", "easy",
   "obviously", "coming soon".

Rules 1, 2 and 6 are grep. Rule 4 is what makes the whole redesign hold,
because a page that declares its mode can be audited against its template by
anyone, including a reviewer who has never read Diátaxis.

## What this style sheet does not claim

Diátaxis is explicit in `diataxis.fr/quality/` that it addresses deep quality
and cannot deliver functional quality. Accuracy, completeness and consistency
come from the craft, not from the rules above. These rules make bad writing
visible. They do not make writing good.
