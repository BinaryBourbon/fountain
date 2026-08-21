# Deliverable 5: `primitives.md` rewritten end to end

Worked example. The before is `docs/primitives.md` at `b4e3314`, 178 lines. The
after is `concepts/index.md` plus four children, and this document gives two of
them in full, the hub and `concepts/vault.md`. Vault is included because the
hub alone cannot demonstrate the HashiCorp collision, which is the single
largest comprehension risk in Fountain's vocabulary.

Every structural decision is numbered and traced at the end.

---

## Before, as a section map

The full text is at `docs/primitives.md`. What matters is the job mix.

| Section | Lines | Modes present |
|---|---|---|
| Environment | 27 | reference, explanation, example |
| Vault | 21 | explanation, reference, how-to |
| Agent | 43 | reference, plus 9 lines of buried explanation |
| Conversation | 21 | how-to (a 5-step API sequence), explanation |
| Status lifecycle | 9 | reference |
| The team: agents as teammates | 41 | explanation, how-to, reference |
| Substitution | 10 | reference |

Four of seven sections do three jobs. The team section is 23% of a page about
primitives and is about a different application. The page contains 12 em
dashes and 19 colon-introduced lists.

The specific damage, in the terms of the working note. The page has inherited
the weakest stopping condition it contains, so nobody can tell when it is
finished. A contributor adding a fifth conversation status cannot tell whether
they owe one edit or three.

---

## After, page 1 of 5

### `docs/concepts/index.md`

```markdown
---
mode: explanation
title: The four primitives
---

# The four primitives

This page explains what Fountain's four objects are and why there are four of
them. For the fields on each one, see the [API reference](../api.md). For
building something with them, start with
[An agent that opens a pull request](../tutorials/first-agent.md).

## The problem the four primitives divide up

To run a coding agent on a machine that is not yours, four things have to be
decided, and they change on four different schedules.

What the machine has on it changes rarely. Python 3.12, a checkout of your
repo, a setup script. You decide it once for a team and leave it alone.

Which credentials the agent runs with changes constantly. A staging database
URL today, a customer's API key tomorrow, a rotated token an hour from now.

How the agent behaves changes occasionally. Which model, which runtime, which
skills, which MCP servers, what its system prompt says.

What it is doing right now changes every few seconds.

Put all four in one object and every credential rotation edits the machine
image, and every prompt edits the credentials. Fountain splits them into four
objects on purpose, and the split is the product.

| Primitive | Answers | Changes |
|---|---|---|
| [Environment](environment.md) | what is on the machine | rarely |
| [Vault](vault.md) | which credentials this run uses | constantly |
| [Agent](agent.md) | how the agent behaves | occasionally |
| [Conversation](conversation.md) | what it is doing right now | continuously |

## How they compose

An Agent names an Environment. A Conversation runs an Agent, and may name a
different Environment and attach a Vault for that run alone.

```
Environment  ──▶  Agent  ──▶  Conversation
     ▲                             │
     └── overridden per run ───────┤
                                   │
Vault ──────── attached per run ───┘
```

At the moment a Conversation starts, Fountain merges the Environment's secrets
with the Vault's secrets and hands the result to the sandbox as environment
variables. **The Vault wins on key collision.** That one rule is why the split
into four is usable rather than merely tidy, and it is explained in
[About vaults](vault.md).

## What Fountain does not have

There is no fifth primitive, and two things that look like one are not.

A **team** is not an object. A teammate is a Conversation bound to the reserved
channel `fountain:team`. See [Agents as teammates](teammates.md).

A **sandbox** is not an object you create. It is provisioned when a
Conversation starts and reclaimed when it ends. See
[About sandboxes](sandboxes.md).

## Where to go next

- Learn by doing.
  [An agent that opens a pull request](../tutorials/first-agent.md) is a
  tutorial that uses all four in about fifteen minutes.
- Understand one primitive.
  [Environment](environment.md), [Vault](vault.md), [Agent](agent.md),
  [Conversation](conversation.md).
- Understand the machinery.
  [How a conversation runs](how-a-conversation-runs.md) follows a prompt from
  the API call to the first token.
- Look something up. The [API reference](../api.md) has every field, and
  [Conversation states](../reference/conversation-states.md) has the state
  table.

---
*Written 2026-08-21 against Fountain 0.12.0.*
```

---

## After, page 2 of 5

### `docs/concepts/vault.md`

```markdown
---
mode: explanation
title: About vaults
---

# About vaults

This page explains what a Fountain Vault is, why it exists, and why it is not
the thing its name suggests. To attach one to a run, see
[Override credentials with a vault](../guides/override-credentials-with-a-vault.md).
For fields, see the [API reference](../api.md#vaults).

## If you have used HashiCorp Vault, read this first

The names collide and the meanings are close to opposite. Getting this
backwards produces exactly the wrong model of how credentials reach a sandbox.

| HashiCorp Vault | Fountain Vault |
|---|---|
| One central server you deploy, cluster and unseal | A small record in Fountain's database. You make as many as you like |
| The authoritative store. If it is in Vault, it is true | A patch layer. The Environment is the baseline and the Vault overrides it |
| Issues dynamic, leased, revocable credentials | Holds static values you wrote. No leases, no rotation, no revocation |
| Sealed until an operator unseals it | No state. There is nothing to unseal |
| Path mounts, per-path policy | A flat key and value bag, scoped to your tenant |
| Precedence is not a concept | Precedence is the entire point |

One thing does carry over. Both encrypt with an envelope. HashiCorp goes unseal
key, then root key, then keyring, then data. Fountain goes `MASTER_SECRETS_KEY`,
then a per-tenant data encryption key, then the value. If you understood
theirs, you understand [ours](secrets.md).

## What a vault is

A Vault is a named bag of environment variables that layers over an
Environment for one run.

It is free-floating. It belongs to no Agent and no Environment, it can be
attached to any conversation your Agent's `allowed_vault_ids` permits, and the
same Vault can be attached to conversations of different Agents at the same
time.

## Why it exists

Without vaults, changing one credential means editing the Environment, and the
Environment is shared. Three consequences follow, and all three are things
teams actually do.

Running the same Agent against staging and production would need two
Environments that are identical except for one URL, and they would drift.

Giving a contractor's agent a scoped token would mean either widening the
shared Environment or cloning it.

Rotating one key would touch every agent using that Environment, whether or not
they use the key.

A Vault makes each of those a one-line attachment on a single run, and leaves
the Environment alone.

## The merge rule

When a Conversation starts, Fountain builds the environment variable set in one
direction.

```
environment secrets  ──merge──▶  vault secrets  ──▶  the sandbox
                                      ▲
                              wins on collision
```

The Vault wins. If the Environment sets `DATABASE_URL` and the attached Vault
also sets `DATABASE_URL`, the process sees the Vault's value.

The merge happens once, at spawn. Editing a Vault does not reach a running
sandbox.

Keys that only the Environment sets survive. A Vault is a patch and not a
replacement.

## What a vault is not

**Not rotation.** A value you put in a Vault stays there until you change it.
Fountain does not expire it, does not renew it, and does not tell the agent it
went stale.

**Not revocation.** Removing a Vault from an Agent's `allowed_vault_ids` stops
future conversations attaching it. A sandbox that is already running keeps the
value it was given, because the value is in a process's environment on a
machine.

**Not a read audit.** Fountain audits the mutation when a secret is written, by
key and by size. It does not record that an agent read one, because the read
happens inside the sandbox.

**Not returnable.** Values are write-only. Listing a Vault returns keys and
timestamps. There is no endpoint that gives you a value back, including for
you, including as the owner.

## When to use something else

Use an **Environment** for anything the whole team shares that is not a
credential. Feature flags, endpoints and package versions belong in
`env_vars`, which is returned by the API as written.

Use **inference credentials** for model API keys. Those are per-user, entered
at `/account/inference-credentials`, and never go in a Vault. See
[Why you bring your own inference credentials](inference-credentials.md).

Use **nothing** when the value is not secret and not per-run. A Vault holding
one non-secret is a Vault someone will later assume is secret.

## What we chose not to do

We considered per-key precedence, so a specific Environment key could refuse to
be overridden. We rejected it. A merge rule that holds always is worth more
than a merge rule that is more expressive, because the reader has to hold it in
their head at the moment they are debugging a wrong credential, which is
usually at a bad time.

We also considered making the Vault the baseline and the Environment the
override, which would have matched the HashiCorp prior. We rejected it because
the thing that changes rarely should be the base.

## Where to go next

- [Override credentials with a vault](../guides/override-credentials-with-a-vault.md),
  a how-to.
- [Where a secret comes from](secrets.md), the full chain from
  `MASTER_SECRETS_KEY` to the process.
- [About environments](environment.md), the other half of the merge.
- [API reference](../api.md#vaults), every field.

---
*Written 2026-08-21 against Fountain 0.12.0.*
```

---

## Pages 3 to 5, and what left the page

`concepts/environment.md`, `concepts/agent.md` and `concepts/conversation.md`
follow the same template and are not reproduced here. What matters for the
audit is that nothing was lost. Every line of the old page has a destination.

| Old content | Went to | Because |
|---|---|---|
| Environment field bullets | `api.md`, existing Environments section | Reference belongs in reference |
| Environment networking semantics | `concepts/environment.md`, "How it works" | Explanation |
| Environment YAML example | `concepts/environment.md`, one example | Illustration is licensed in explanation |
| Vault merge rule | `concepts/vault.md`, "The merge rule" | The most important sentence on the page, promoted to a heading |
| Vault "Typical uses" | `guides/override-credentials-with-a-vault.md` | It was a how-to in three words |
| Agent field bullets | `api.md` | Reference |
| The 9-line `model` argument | `concepts/agent.md`, "Why the provider is checked and the model id is not" | Findable under a question, not a field name |
| Agent skills bullet | `concepts/agent.md` plus `catalog/skills/` | The bundled `fountain` and `create-team` skills get pages |
| Agent `mcp_servers` bullet | `concepts/agent.md` plus `catalog/mcp-servers/` | Same |
| Conversation 5-step sequence | `guides/interrupt-resume-end.md` and the tutorial | It was a how-to inside an explanation |
| Suspend and destroy admonition | `concepts/conversation.md`, "How it works" | Explanation, expanded to Modal's per-state depth |
| `SANDBOX_IDLE_TIMEOUT_MINUTES`, `SANDBOX_MAX_LIFETIME_HOURS` | `configuration.md` | Reference |
| Status lifecycle diagram | `reference/conversation-states.md` | Its own page, with a row per state |
| "The team", 41 lines | `concepts/teammates.md` and `guides/schedule-a-teammate.md` | Explanation and how-to, separated |
| Substitution table | `api.md` plus `concepts/secrets.md` | Reference, with the chain explained once |

---

## Every structural decision, traced

**1. The hub opens with the reader's problem, not a definition.**
`tailscale.com/blog/how-tailscale-works` builds hub-and-spoke, steelmans it,
then enumerates what breaks, and never uses an adjective to sell. The four
paragraphs about change rates are Fountain's version. The old page opened
"Everything in Fountain is built from four concepts", which asserts the
conclusion and skips the argument.

**2. The four primitives are motivated by four different change rates, and by
what breaks if you merge them.** This is Temporal's justify-by-failure, from
`docs.temporal.io/activities.md`, where the primitive is motivated by naming
what fails without it. Also Stripe's, where three of the four Payment Intents
advantages at `docs.stripe.com/payments/payment-intents` are avoided failures.
The old page listed features.

**3. The comparison table has a "Changes" column.** That column is the
argument, compressed. `diataxis.fr/explanation/` says explanation "joins things
together"; a table whose only columns are name and definition joins nothing.

**4. The composition diagram is on the hub and nowhere else.** Fly.io's
`fly.io/docs/machines/` is a three-item hub whose job is entirely to route, and
`/docs/machines/overview/` does the explaining. Splitting hub from explanation
is what stops the hub growing to 178 lines again.

**5. "What Fountain does not have" is a required section.** Temporal, Modal and
Fly all independently carry a negative boundary. Temporal, "If you only want to
execute one Activity Function, then you don't need to use a Workflow." Modal,
routing readers to Functions. Fly, "For most applications, most of the time,
you don't need to be picky!" Fountain needs it more than any of them, because
"is a team a fifth primitive" is a real question the old page half-answered in
its 41-line team section.

**6. "Where to go next" labels the mode of each link.**
`docs.temporal.io/temporal.md` ends with five Next steps that route to a
tutorial, a how-to and two explanations, and say which is which. The old page
had no exits at all, which is why `tour.md` went unlinked.

**7. Vault opens with the HashiCorp collision, before the definition.**
`developer.hashicorp.com/vault/docs/what-is-vault` and
`/vault/docs/concepts/seal` establish a prior that is not merely different from
Fountain's but inverted on the one fact that matters, which is which layer is
authoritative. Temporal's noun-disambiguation move at
`docs.temporal.io/workflows.md` ("the term Workflow might refer to Workflow
Type, a Workflow Definition, or a Workflow Execution") is the same instinct
applied to an internal collision. Fountain's collision is external and worse.

**8. The collision table ends by naming what does transfer.** Both products
use envelope encryption in the same shape. Saying "no, not like Vault" six
times and then "yes, exactly like Vault" once gives the reader something to
keep, and it is the same move Tailscale makes when it credits `wireguard-go` by
exact variant instead of claiming the mechanism.

**9. "The merge rule" is its own H2 with a diagram.** It was the fourth
sentence of a 21-line section, introduced by a colon. It is the one fact a
reader must have to use vaults at all.

**10. "What a vault is not" enumerates four negatives, each stating the
mechanism.** Modal's Finished state at `modal.com/docs/guide/sandbox`
enumerates all five ways a sandbox can stop rather than saying "for various
reasons". The revocation entry here does the same thing, explaining that a
running sandbox keeps its value because the value is already in a process's
environment. The audit found that a HashiCorp reader will silently assume
rotation and revocation, and no current page denies it.

**11. "What we chose not to do" is present.** `diataxis.fr/explanation/` is the
only mode that admits opinion and says explanation "must consider alternatives,
counter-examples or multiple different approaches". Fountain writes ADRs
already, so the reasoning exists; this section is where it becomes readable.

**12. The page is dated and stamped with a version.**
`tailscale.com/blog/how-tailscale-works` carries a byline and 20 March 2020, so
a 2020 claim reads as one. Explanation is the mode most likely to go quietly
stale, because unlike reference nothing in CI compares it to the code.

**13. Every code fence on these pages is illustration, and none is a step.**
Stripe's rule from `docs.stripe.com/payments/payment-intents`, where four
`curl` blocks are the same base request with exactly one parameter changed, so
no block depends on a previous one. The old Conversation section's five
numbered steps failed this test, which is why they left for a how-to.

**14. The status lifecycle became its own reference page.** Fly gives
`/docs/machines/machine-states/` and `/docs/volumes/volume-states/` dedicated
URLs rather than sections inside an overview. The new page follows Modal's
depth rather than Fly's, giving each state a row that says what exists, what
does not exist yet, and which operations are legal, because a diagram tells you
the edges and not what you may call.

**15. The team section left entirely.**
`diataxis.fr/explanation/`, "Keep explanation closely bounded", warns that
explanation absorbs other things and that letting instruction creep in both
interferes with the explanation and removes the instruction from view in its
correct place. Forty-one lines of another application's cron feature is the
textbook case.

**16. No em dashes, no colon-introduced lists, no trailing clauses.** The old
page has 12 and 19 of the first two. The rewrite has none. The third rule is
what turned the `model` bullet from one 60-word sentence into five sentences
under a findable heading, which is the whole argument for the rule in
deliverable 4.
