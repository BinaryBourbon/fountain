# Deliverable 1: proposed nav tree

> **Shipped with one change.** The `mkdocs.yml` nav parser takes one level of
> sections and raises on anything deeper, so the Guides sub-groupings below
> flattened into sibling sections. What shipped is `Concepts`, `Run an
> instance`, `Troubleshooting`, `Catalog` and `Reference`. See #903.

Every entry is labelled with its Diátaxis mode and its disposition.
**KEEP**, **MOVE**, **SPLIT**, **MERGE**, **NEW**, **DELETE**.

Section names are in reader language rather than Diátaxis vocabulary, following
Temporal's `docs.temporal.io/llms.txt`, which uses Core Primitives, SDK
Development Guides, References, Guides, Troubleshooting. `diataxis.fr/explanation/`
licenses this directly, listing Discussion, Background, Conceptual guides and
Topics as acceptable names for explanation. The discipline being enforced is
one mode per section, not the naming.

---

## The tree

### Start here

| Page | Mode | Disposition |
|---|---|---|
| `index.md`, Fountain | hub | **KEEP**, rewritten. Nine undifferentiated links become four mode-labelled doors, following Temporal `/temporal.md`'s "Next steps" |
| `start/what-fountain-is.md` | Explanation | **NEW**. Replaces `index.md`'s "Why Fountain?". Built on Tailscale's status-quo-then-break shape |
| `tutorials/first-agent.md`, An agent that opens a pull request | **Tutorial** | **MOVE** from `tour.md`, unchanged in content, promoted to position 2 |
| `start/install.md`, Install the CLI and sign in | How-to | **NEW**. Extracted from `cli.md` "Install" plus "Authentication" |

The tutorial appears here and in Tutorials. One page, two nav positions.
`diataxis.fr/map/` is explicit that a user "may enter the documentation
anywhere", so a single canonical order is not required.

### Concepts

Everything in this section is explanation. Nothing in it contains a numbered
step or a complete field list.

| Page | Mode | Disposition |
|---|---|---|
| `concepts/index.md`, The four primitives | Explanation | **SPLIT** from `primitives.md`. Becomes a hub. Full rewrite in deliverable 5 |
| `concepts/environment.md` | Explanation | **SPLIT** from `primitives.md` lines 7 to 33 |
| `concepts/vault.md` | Explanation | **SPLIT** from `primitives.md` lines 34 to 54, plus the HashiCorp collision section. Rewrite in deliverable 5 |
| `concepts/agent.md` | Explanation | **SPLIT** from `primitives.md` lines 55 to 97. The 9-line `model` argument becomes prose under its own heading |
| `concepts/conversation.md` | Explanation | **SPLIT** from `primitives.md` lines 98 to 118 |
| `concepts/how-a-conversation-runs.md` | Explanation | **MERGE** of `architecture.md` "A conversation's life" and `build/pieces.md` "What happens between Enter and the first word" and "The computer's day" |
| `concepts/secrets.md`, Where a secret comes from | Explanation | **NEW**. Joins `architecture.md` "The secrets model", the vault merge rule, and `${VAR}` substitution into one chain. Audit gap 5 |
| `concepts/sandboxes.md` | Explanation | **SPLIT** from `integrations/sandbox-contract.md`, explanation half only |
| `concepts/inference-credentials.md`, Why you bring your own | Explanation | **MOVE** from `integrations/index.md` "The service you do not configure" |
| `concepts/teammates.md`, Agents as teammates | Explanation | **SPLIT** from `primitives.md` lines 128 to 168, explanation half only |
| `concepts/surfaces.md`, The console, the apps, and the API | Explanation | **NEW**. Audit gap 6. Currently only in `CLAUDE.md` |
| `concepts/architecture.md` | Explanation | **MOVE** from `architecture.md`, minus the two merged sections and the "Where to look" nav list |
| `concepts/why-a-chat-app-needs-this.md` | Explanation | **MOVE** from `build/index.md`. Genuinely good explanation currently filed under a tutorial section |

### Tutorials

| Page | Mode | Disposition |
|---|---|---|
| `tutorials/first-agent.md` | **Tutorial** | Same page as in Start here |
| `tutorials/team-chat.md` | **Tutorial** | **MOVE** from `build/team-chat.md` |

Two tutorials is the right number. `diataxis.fr/tutorials/` is blunt that they
"can consume a remarkable amount of effort and time" and that revisions
"cascade through the entire story". Adding a third is a maintenance commitment,
not a page.

### Guides

Everything here is how-to, and every title starts with a verb, per
`diataxis.fr/how-to-guides/`, "Pay attention to naming".

#### Run agents

| Page | Mode | Disposition |
|---|---|---|
| `guides/give-an-agent-a-repo.md` | How-to | **NEW**. Extracted from `tour.md` stage 1 and `cli.md` "Apply manifests" |
| `guides/override-credentials-with-a-vault.md` | How-to | **MOVE** from `primitives.md` Vault "Typical uses", expanded |
| `guides/interrupt-resume-end.md` | How-to | **NEW**. From `primitives.md` Conversation steps 4 and 5, and `api.md` |
| `guides/schedule-a-teammate.md` | How-to | **SPLIT** from `primitives.md` "Schedules" |
| `guides/stream-a-conversation.md` | How-to | **SPLIT** from `sdk.md` "Awaiting, streaming, or neither" |

#### Operate an instance

`self-hosting.md` (393 lines) and `operations.md` (290 lines) become nine
pages. Each has one reader arriving at one moment.

| Page | Mode | Disposition |
|---|---|---|
| `guides/operate/deploy.md` | How-to | **SPLIT** from `self-hosting.md` "Quick start" |
| `guides/operate/put-it-on-the-internet.md` | How-to | **SPLIT** from `self-hosting.md` |
| `guides/operate/database.md` | How-to | **SPLIT** from `self-hosting.md` "Database" and "Running migrations in a Job" |
| `guides/operate/back-up-and-restore.md` | How-to | **MERGE** of `self-hosting.md` "Backups" and `operations.md` "Backup and restore" including the restore drill |
| `guides/operate/upgrade.md` | How-to | **MERGE** of `self-hosting.md` "Versioning and upgrades" and `operations.md` "Upgrade gone wrong" |
| `guides/operate/turn-on-billing.md` | How-to | **SPLIT** from `self-hosting.md` "Billing" |
| `guides/operate/set-sandbox-lifetimes.md` | How-to | **SPLIT** from `self-hosting.md` "Sandbox lifetime" |
| `guides/operate/observability.md` | How-to | **MERGE** of `self-hosting.md` "Observability" and `operations.md` "Pods restarting or not ready" |
| `guides/operate/run-a-release-task.md` | How-to | **SPLIT** from `operations.md` |
| `guides/operate/kubernetes.md` | How-to | **SPLIT** from `self-hosting.md` "Kubernetes" |

#### Contribute

| Page | Mode | Disposition |
|---|---|---|
| `guides/contribute/set-up-a-workstation.md` | How-to | **MOVE** from `setup.md` |
| `guides/contribute/add-a-sandbox-provider.md` | How-to | **MOVE** from `integrations/adding-a-sandbox-provider.md` |
| `guides/contribute/write-a-catalog-entry.md` | How-to | **NEW**. The template from deliverable 3, as an executable guide |

### Catalog

New top-level section. Six sub-catalogs, one entry template (deliverable 3).

| Page | Mode | Disposition |
|---|---|---|
| `catalog/index.md` | Reference index | **NEW** |
| `catalog/sandboxes/index.md` | Reference index | **NEW** |
| `catalog/sandboxes/sprites.md` | Catalog entry | **MOVE** from `integrations/sprites.md`, refiled to template |
| `catalog/sandboxes/e2b.md` | Catalog entry | **MOVE** from `integrations/e2b.md` |
| `catalog/sandboxes/daytona.md` | Catalog entry | **MOVE** from `integrations/daytona.md` |
| `catalog/sandboxes/self-hosted-runner.md` | Catalog entry | **MOVE** from `integrations/runners.md`, explanation half to `concepts/sandboxes.md`, wire protocol to Reference |
| `catalog/clients/index.md` | Reference index | **MOVE** from `integrations/clients.md` |
| `catalog/clients/editors.md` | Catalog entry | **MOVE** from `integrations/editors.md` |
| `catalog/clients/openclaw.md` | Catalog entry | **MOVE** from `integrations/openclaw.md` |
| `catalog/clients/hermes.md` | Catalog entry | **MOVE** from `integrations/hermes.md` |
| `catalog/clients/openbot.md` | Catalog entry | **MOVE** from `integrations/openbot.md` |
| `catalog/clients/buzz.md` | Catalog entry | **MOVE** from `integrations/buzz.md`, runbook half to Troubleshooting |
| `catalog/clients/agentic-ides.md` | Catalog entry | **SPLIT** from `llm-integration.md` |
| `catalog/services/index.md` | Reference index | **MOVE** from `integrations/index.md`, minus the inference-credentials essay |
| `catalog/services/mail.md` | Catalog entry | **MOVE** from `integrations/mail.md` |
| `catalog/services/github-oauth.md` | Catalog entry | **MOVE** from `integrations/github-oauth.md` |
| `catalog/services/stripe.md` | Catalog entry | **MOVE** from `integrations/stripe.md` |
| `catalog/services/sentry.md` | Catalog entry | **MOVE** from `integrations/sentry.md` |
| `catalog/runtimes/index.md` | Reference index | **NEW**. Audit gap 4 |
| `catalog/runtimes/{claude,codex,gemini,opencode}.md` | Catalog entry x4 | **NEW** |
| `catalog/mcp-servers/index.md` | Reference index | **NEW**. Known gap 2 |
| `catalog/mcp-servers/*.md` | Catalog entry | **NEW**. Start with the ones actually in use |
| `catalog/skills/index.md` | Reference index | **NEW**. Known gap 2 |
| `catalog/skills/fountain.md` | Catalog entry | **NEW**. Injected into every sandbox and documented nowhere |
| `catalog/skills/create-team.md` | Catalog entry | **NEW**. Same, and it owns the `/create-team` command |

### Reference

Austere and neutral, per `diataxis.fr/reference/`. No voice, no
recommendations, no numbered procedures.

| Page | Mode | Disposition |
|---|---|---|
| `cli.md` | Reference | **KEEP AT THIS PATH**. See the constraint below |
| `api.md` | Reference | **KEEP** |
| `sdk-reference.md` | Reference | **SPLIT** from `sdk.md`, reference half |
| `configuration.md` | Reference | **KEEP** |
| `reference/conversation-states.md` | Reference | **NEW**. Promoted out of `primitives.md`. Fly gives Machine states and Volume states their own pages |
| `reference/acp.md` | Reference | **MOVE** from `integrations/acp.md` |
| `reference/sprites-transport.md` | Reference | **MOVE** from `integrations/sprites-contract.md` |
| `reference/sandbox-contract.md` | Reference | **SPLIT** from `integrations/sandbox-contract.md`, reference half |
| `reference/runner-protocol.md` | Reference | **SPLIT** from `integrations/runners.md` "The wire protocol" |
| `reference/discovery-endpoints.md` | Reference | **SPLIT** from `llm-integration.md` "Discovery endpoints" |
| `reference/glossary.md` | Reference | **NEW**. Audit gap 3. Temporal keeps `/glossary.md` in its Concepts section |
| `changelog.md` | Reference | **KEEP** |

### Troubleshooting

New top-level section, one problem per page, titled as the symptom the reader
observes. Temporal keeps `/troubleshooting/` as a peer of its other trees.

| Page | Mode | Disposition |
|---|---|---|
| `troubleshooting/index.md` | hub | **NEW** |
| `troubleshooting/conversation-stuck-or-failed.md` | How-to | **MOVE** from `operations.md` |
| `troubleshooting/nobody-can-log-in.md` | How-to | **MOVE** from `operations.md` |
| `troubleshooting/sandbox-errors.md` | How-to | **MERGE** of `operations.md` "Sprites errors" and the four scattered "When something goes wrong" sections on `acp.md`, `editors.md`, `openclaw.md`, `buzz.md`, `openbot.md` |
| `troubleshooting/setup-problems.md` | How-to | **MOVE** from `setup.md` "Troubleshooting" |

---

## What gets deleted

| Page or section | Why |
|---|---|
| `index.md` "Why Fountain?" | Motivates by repository lineage. Replaced by `start/what-fountain-is.md` |
| `llm-integration.md` "MCP server (coming soon)" | Documents unbuilt behavior with a copy-pasteable config block. Violates `CLAUDE.md`'s own rule. Restore it in the PR that ships the server |
| `architecture.md` "Where to look" | A nav list inside a page. The nav is the nav |
| `build/pieces.md` | Fully absorbed by `concepts/how-a-conversation-runs.md` and `concepts/surfaces.md`. Its "Where the multi-tenancy is" section moves to `concepts/architecture.md` |
| `integrations/index.md` as a page | Becomes `catalog/services/index.md`. Its essay moves to `concepts/inference-credentials.md` |
| `sdk.md` as a single page | Splits into a Guides entry and `sdk-reference.md` |

Nothing else is deleted. Every one of the 34 current pages survives as content.

## Summary of movement

| | Count |
|---|---|
| Pages today | 34 |
| Kept at their path | 5 |
| Moved | 19 |
| Split into two or more | 8 source pages, producing 31 |
| Merged | 6 source sections into 3 |
| Written new | 24, of which 11 are catalog scaffolding |
| Deleted outright | 1 page, 3 sections |
| Pages after | roughly 88, of which about 35 are catalog entries |

The page count roughly doubles. That is the point. `diataxis.fr/how-to-guides/`
argues the list of how-to guides "helps frame the picture of what your product
can actually do", and Fountain currently hides ten runbooks inside two pages.

## Ordered sequence of individually mergeable steps

`diataxis.fr/how-to-use-diataxis/` is explicit that this tree should not be
built as a plan, that empty structures are "horrible", and that structure
should emerge from small improvements. So the tree above is the destination,
and this is the order. Every step is one PR that leaves the docs better and
passes `mkdocs build --strict` and `docs_test.exs` on its own.

1. **Link the two tutorials from `index.md` and move `tour.md` to nav position
   2.** One file, two lines, plus the `docs.ex` mirror. Fixes the highest-value
   defect in the audit and creates no new structure.
2. **Rewrite `index.md`'s "Why Fountain?" as `start/what-fountain-is.md`.** One
   new page, one deletion.
3. **Delete the "coming soon" MCP config block.** Zero new pages.
4. **Split `primitives.md`.** One hub plus four children plus
   `reference/conversation-states.md`. This is deliverable 5 and it is the
   first step that creates a section, and the section arrives full.
5. **Add `reference/glossary.md`.** Cheap, and every later page can link into
   it.
6. **Split `operations.md` into Troubleshooting.** Creates the second section,
   also full on arrival.
7. **Split `self-hosting.md` into `guides/operate/`.**
8. **Refile the existing 19 integration pages onto the catalog template**, one
   page per PR, starting with `mail`, `github-oauth`, `sentry` and `stripe`,
   which are already closest to it.
9. **Add the two empty catalogs last**, `mcp-servers` and `skills`, each
   arriving with at least three real entries. Never ship the index alone.

Steps 1 through 3 are half a day and are worth doing regardless of whether the
rest of this is adopted.

## Two constraints that carry code changes

**`docs/cli.md` cannot move or split** until
`cli/internal/cmd/docs_test.go`'s `readCLIDoc` is changed. It opens
`../../../docs/cli.md` by hardcoded path and nothing else, and both tests in
that file scan only that string. The fix is small, which is to walk a directory
and concatenate, but it is a Go change and belongs in its own PR before step 8.

**Sections are one level deep, and that is enforced by a raise.** The
`mkdocs.yml` nav parser in `Fountain.Docs` reads exactly two line shapes, and
anything else raises at compile time. So `Guides > Operate > page` is not
representable. The Guides sub-groupings above must flatten into sibling
sections, for example `Guides: run agents` and `Guides: operate`, or become
in-page headings on a hub.
