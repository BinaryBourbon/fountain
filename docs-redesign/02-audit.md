# Phase 3: audit of the current docs

Crawled `https://fountain.inevitable.fyi/docs` and the `docs/` source tree they
are built from. The two agree, so the source is the audit target.

**Correction to the brief's scope.** The brief names seven pages (index, setup,
architecture, primitives, cli, api, llm-integration). The live site has 34,
plus a `changelog`. The extra 27 are `self-hosting`, `operations`,
`configuration`, `sdk`, `tour`, three `build/*` pages, and nineteen
`integrations/*` pages. Most of the findings below are about those 27.

## Mode classification, all 34 pages

Mode column is what the page *is*, not what it is filed as. "Jobs" counts the
distinct Diátaxis modes doing real work on the page.

| Page | Lines | Actual mode(s) | Jobs |
|---|---|---|---|
| `index.md` | 36 | hub, with explanation in "Why Fountain?" | 2 |
| `setup.md` | 109 | how-to | 1 |
| `self-hosting.md` | 393 | how-to x8, reference x2, explanation x1 | 3 |
| `architecture.md` | 187 | explanation, with a nav list and a lifecycle narration | 2 |
| `operations.md` | 290 | how-to x7 | 1 |
| `configuration.md` | 207 | reference | 1 |
| `primitives.md` | 178 | explanation, reference, how-to | 3 |
| `cli.md` | 279 | reference, with how-to prose | 2 |
| `api.md` | 629 | reference | 1 |
| `sdk.md` | 374 | how-to, reference, explanation | 3 |
| `tour.md` | 208 | tutorial | 1 |
| `llm-integration.md` | 65 | how-to, reference, roadmap | 3 |
| `build/index.md` | 118 | explanation | 1 |
| `build/team-chat.md` | 401 | tutorial | 1 |
| `build/pieces.md` | 161 | explanation | 1 |
| `integrations/index.md` | 39 | reference table, explanation | 2 |
| `integrations/clients.md` | 69 | hub | 1 |
| `integrations/sandbox-contract.md` | 82 | explanation, reference | 2 |
| `integrations/sprites.md` | 49 | how-to, reference | 2 |
| `integrations/e2b.md` | 52 | how-to, reference | 2 |
| `integrations/daytona.md` | 50 | how-to, reference | 2 |
| `integrations/runners.md` | 146 | how-to, reference, explanation | 3 |
| `integrations/adding-a-sandbox-provider.md` | 133 | how-to | 1 |
| `integrations/sprites-contract.md` | 168 | reference | 1 |
| `integrations/acp.md` | 146 | reference | 1 |
| `integrations/editors.md` | 188 | how-to, explanation, reference | 3 |
| `integrations/openclaw.md` | 271 | how-to, explanation, reference | 3 |
| `integrations/hermes.md` | 136 | how-to, reference | 2 |
| `integrations/openbot.md` | 204 | how-to, explanation, reference | 3 |
| `integrations/buzz.md` | 395 | how-to, explanation, reference, ops runbook | 4 |
| `integrations/mail.md` | 61 | how-to, reference | 2 |
| `integrations/github-oauth.md` | 47 | how-to, reference | 2 |
| `integrations/stripe.md` | 111 | how-to, reference | 2 |
| `integrations/sentry.md` | 46 | how-to, reference | 2 |
| `changelog.md` | 5 | reference (include) | 1 |

**13 of 34 pages do exactly one job. 21 do two or more.** Six do three or more.

## Where pages do two jobs at once

### `primitives.md`, the worst case

Section-by-section, by line range.

| Section | Lines | Doing |
|---|---|---|
| Environment (7 to 33) | 27 | reference (field list), explanation (networking semantics), example |
| Vault (34 to 54) | 21 | explanation (the merge rule), reference, how-to ("Typical uses") |
| Agent (55 to 97) | 43 | reference, plus a 9-line explanation buried inside one bullet |
| Conversation (98 to 118) | 21 | how-to (a 5-step API sequence), explanation (the suspend admonition) |
| Status lifecycle (119 to 127) | 9 | reference |
| The team (128 to 168) | 41 | explanation, how-to (Schedules), reference |
| Substitution (169 to 178) | 10 | reference |

Two specific defects follow from this.

**The `model` field's explanation is longer than the Substitution section and
is unfindable.** Lines 57 to 65 argue why a provider outside `anthropic`,
`openai`, `google` is rejected at write time, and why the model id itself is
not validated. That is good, load-bearing explanation. It is filed under a
field name inside a bullet list, so nobody who wants "why can't I use my own
provider" will ever find it.

**"The team: agents as teammates" is 41 lines, 23% of the page, about a
different application.** It explains a channel binding, then documents the
schedules feature of the team app in prose, including cron syntax and the
one-off-computer toggle. Per `diataxis.fr/explanation/`, "Keep explanation
closely bounded"; this section has absorbed a how-to for a product that ships
from a different repo.

### The other multi-job pages, briefly

- **`self-hosting.md`, 393 lines.** Contains at least eight distinct how-tos
  (deploy, upgrade, configure a database, run migrations in a Job, take
  backups, configure email, change sandbox lifetime, turn on billing, put it on
  the internet, wire observability, deploy to Kubernetes), plus a reference
  (health endpoints), plus a "Known gaps" explanation. Every one of these has a
  different reader arriving at a different moment. Bounded by nothing.
- **`operations.md`, 290 lines.** Seven runbooks on one page. Correct mode,
  wrong granularity. An operator with a stuck conversation at 3am is scrolling
  past a Postgres restore drill.
- **`buzz.md`, 395 lines.** The single largest integration page, doing setup,
  concept, protocol reference, and an operator runbook ("Operating a hosted
  agent", "When something goes wrong").
- **`sdk.md`.** "What the second argument is for" and "Awaiting, streaming, or
  neither" are explanation sections inside a how-to page. They are also the two
  best-written sections on the page, which is the `diataxis.fr` observation
  that trapped explanation is good writing in the wrong place.
- **`llm-integration.md`.** Ships a JSON config block for an MCP server under
  the heading "MCP server (coming soon)". The block looks copy-pasteable. This
  violates the repo's own rule in `CLAUDE.md`, which says documents must not
  describe unbuilt behavior as existing.

### The writers have already invented an explanation template

Three integration pages independently grew the same two headings.
`editors.md` and `openclaw.md` both have "What this is, and is not", and
`editors.md`, `openclaw.md` and `buzz.md` all have "Limits, stated rather than
discovered". `openbot.md` has "What it does not do yet".

This is evidence, not coincidence. Writers keep needing a place to put the
negative boundary and the honest limits, and with no explanation section
available they are embedding one inside every how-to. That heading pair should
be promoted into the template rather than reinvented per page.

## Confirming or refuting the four known gaps

### 1. "No concepts tree separate from task pages". CONFIRMED

There is no explanation section. Explanation exists and is substantial, and it
is scattered across at least nine locations.

`architecture.md` (whole page), `build/index.md` (whole page),
`build/pieces.md` (whole page), `primitives.md` (interleaved),
`integrations/sandbox-contract.md` ("What the contract guarantees"),
`integrations/index.md` ("The service you do not configure", which is a
first-rate ADR summary buried under a table of env vars), `sdk.md` (two
sections), and the "What this is, and is not" / "Limits" sections on four
client pages.

Consequence, using Temporal's shape as the comparison. A reader who wants to
understand Fountain before using it has no door. `docs/index.md`'s "Get
started" list offers Local setup, Architecture, Primitives deep-dive, CLI, API,
LLM integration, Build a chat app, Plugging into Fountain, Services. Two of
those nine are explanation, and they are second and third in a list that reads
as a task list.

### 2. "MCP servers, skills, repos and packages have no catalog". CONFIRMED, and worse than stated

`grep` across `docs/` finds `skills` mentioned on 12 pages and documented
nowhere. The complete public documentation of the skills capability is one
bullet inside the Agent primitive, `primitives.md` line 71. That bullet also
reveals that **two skills are injected into every sandbox in the world**,
`fountain` and `create-team`, and that `create-team` is triggered by a user
typing `/create-team`. Neither has a page. A user cannot find out what
`/create-team` will ask them.

`mcp_servers` is the same. One bullet, one YAML example using
`@modelcontextprotocol/server-github`, and `${VAR}` substitution in its env.
There is no page for that server or any other, no list of what works, no
statement of which transports are supported.

`packages` and `repos` are worse still. They appear only as the words "packages
to install, repos to clone, a setup script" in one line of the Environment
section, plus a `packages: {python: "3.12"}` example. What package managers
exist is discoverable only by calling `GET /api/catalog`, which
`api.md` line 174 says returns "package managers" among other things.

**There is a machine-readable catalog and no human-readable one.**
`GET /api/catalog` returns runtimes, model suggestions per runtime, sandbox
providers, package managers, avatar bases and moods, and app URLs. That is the
data a catalog index page would render, and it renders for agents only.

### 3. "'Why Fountain?' motivates via an earlier personal repo". CONFIRMED

`docs/index.md`, whole section, three sentences. It names
`jhgaylor/aod-ex` and describes Fountain as that project's core rebuilt for
multi-tenancy.

Two separate problems. The reader's problem appears only in a subordinate
clause ("Running Claude instances with worktrees locally and shuffling MCP
configurations and skill setups by hand is painful"), and the paragraph's
actual subject is repository lineage, which is of interest to about four
people. Compare Tailscale, which spends roughly a third of a long page inside
the reader's current setup before naming the product, and Temporal's
`/temporal.md`, which never mentions its own history.

The marketing site at `fountain.inevitable.fyi` already does this job properly.
Its second paragraph is "Manual configuration doesn't scale. New teammates
spend afternoons reverse-engineering setup instead of writing code. API keys
expire mid-sprint with no single source of truth. Parallel tasks with different
credentials mean maintaining separate local checkouts." That is three concrete
failures of the reader's status quo. The docs index has the weaker version of a
paragraph the marketing site already wrote well.

### 4. "The guided tour lives on marketing rather than the docs index". REFUTED, and the real defect is worse

Verified by fetching both. The tour is **not on the marketing site**. I fetched
`https://fountain.inevitable.fyi/` and the rendered text contains no tour, no
walkthrough, and no link matching `tour`.

The tour is at `docs/tour.md`, 208 lines, served at `/docs/tour`, titled "A
guided tour: an agent that opens a pull request". It is the best page in the
repository. It is a clean tutorial with an announced destination, six numbered
stages, a real observable result, a cleanup step, a "What you just built"
recap, and the whole thing repeated as one copyable script.

The actual defects are these.

- **It is not linked from `docs/index.md`.** The "Get started" list has nine
  entries and the tutorial is not among them.
- **It sits at position 15 of 34 in the `mkdocs.yml` nav**, below the CLI
  reference, the API reference and the TypeScript SDK. A newcomer meets three
  reference pages before the lesson.
- **The second tutorial has the same problem.** `build/team-chat.md`, 401
  lines, is also a real tutorial and is also absent from the index.

So Fountain has two good tutorials and no visible way in. Per
`diataxis.fr/tutorials-how-to/`, tutorial/how-to conflation is harmful "because
it risks getting in the way of those newcomers whom we hope to turn into
committed users". Fountain has not conflated them. It has hidden them.

## What a reader cannot currently find

Six gaps beyond the four above, each stated as the question that has no page.

1. **"My conversation failed. Now what?"** `operations.md` is operator-facing
   and assumes `kubectl` and Flux. Four client pages have their own "When
   something goes wrong" sections. There is no user-facing troubleshooting
   door.
2. **"What are all the conversation statuses and what can I do in each?"**
   Nine lines inside `primitives.md`, as an ASCII arrow diagram plus one
   sentence about `terminated`. It says nothing about what operations are legal
   in each state. Compare Modal's Sandbox lifecycle, which gives each state a
   paragraph, and Fly, which gives Machine states its own page.
3. **"What does this word mean?"** No glossary. Fountain overloads at least
   five terms. "Environment" is a primitive, a map of env vars, and a
   deployment tier. "Agent" is a primitive, the coding agent running in the
   sandbox, and the ACP role. "Computer" is used throughout the team docs for
   the sandbox and is defined nowhere. "Sandbox", "sprite", "runner" and
   "machine" all appear. "Fountain" is the product, the CLI binary, and a skill
   injected into every sandbox.
4. **"Which runtime should I pick?"** Four runtimes exist. The differences are
   scattered across the `model` bullet in `primitives.md`, `acp.md` ("ACP is
   the ONLY path for claude/codex/opencode"), and `configuration.md`. No
   comparison exists.
5. **"How does the secret actually get into my sandbox?"** The pieces exist in
   three places. `architecture.md`'s "The secrets model", the Vault merge rule
   in `primitives.md`, and the Substitution table. Nothing joins the chain from
   `MASTER_SECRETS_KEY` through the per-tenant DEK through the environment plus
   vault merge through `${VAR}` substitution to the process environment.
6. **"Why is there a console and also two separate apps?"** This is a real
   architectural decision with real consequences for anyone building against
   Fountain, and it is documented only in `CLAUDE.md`, which is a contributor
   file, plus a redirect note. `docs/` never states it.

## Cross-cutting style findings

Measured across the 34 pages.

- **682 em dashes, in 32 of 34 files.** `api.md` alone has 61,
  `architecture.md` 32, `primitives.md` 12.
- **Colon-introduced lists are the default construction.** 19 in
  `primitives.md`, 12 in `api.md`, 10 in `cli.md`, 8 in `architecture.md`.
- **Trailing explanatory clauses are pervasive**, and they are where the
  explanation hides. The `model` bullet is one 60-word sentence with three
  subordinate clauses after the claim.

These are addressed in deliverable 4.

## Two structural facts that constrain any redesign

Both are in `CLAUDE.md` and both are real gates, not conventions.

1. **The nav lives only in `mkdocs.yml`, and its parser is strict.**
   `Fountain.Docs` parses that file's `nav:` at compile time
   (`docs.ex:43`), so there is nothing to mirror. Two real constraints remain.
   The parser handles **one level of sections only** and raises on a line it
   cannot read, so a nested sub-section fails the build. And
   `docs_test.exs` renders every page and asserts each `](/docs/x#anchor)`
   target is a real heading, so renaming a heading breaks its inbound links.

   Note. `/Users/jake/CLAUDE.md`'s copy of the contributor guide still
   describes a hand-mirrored `@nav`. The version on `main` was already
   corrected. The stale copy is what the nav tree in deliverable 1 was
   originally written against, and its "every nav edit is two files" claim is
   wrong.
2. **`docs/cli.md` is diffed against the CLI, by hardcoded path.** I read
   `cli/internal/cmd/docs_test.go`. `readCLIDoc` opens
   `../../../docs/cli.md` and nothing else. `TestEveryCommandIsDocumented`
   walks the real Cobra tree and fails if any command string is absent from
   that one file. `TestNoDocumentedCommandIsInvented` scans only fenced code
   blocks in that file and fails on any invented command.

   Consequence for this redesign. The CLI reference **must stay as one file at
   `docs/cli.md`**, or `readCLIDoc` must be changed to concatenate a directory
   before any split happens. This is the only proposal in deliverable 1 that
   carries a code change outside `docs/` and `docs.ex`, and it is called out
   there.
