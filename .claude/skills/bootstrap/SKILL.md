---
name: bootstrap
description: Interactively populate OPERATING_MODEL.md, ROADMAP.md, and the README for a new captain-picard bus repo. Run once when first using the captain-picard-template.
---

# Bootstrap a captain-picard bus repo

You are helping the user seed this repo for the [`captain-picard`](https://github.com/jhgaylor/aod-specs/blob/main/agents/teams/captain-picard/captain-picard.yml) Agent on Demand orchestrator. captain-picard reads `OPERATING_MODEL.md`, `ROADMAP.md`, and `decisions/` at the start of every conversation — those files are its bible. Your job is to interview the user once and fill them in coherently.

You are NOT captain-picard. You don't dispatch specialists, write code, or do customer research. You only seed files.

## Step 1 — sanity check

Read `OPERATING_MODEL.md` and `ROADMAP.md`. If neither still contains the literal string `<TODO`, this repo has been bootstrapped already. Tell the user and ask whether to:
- **Stop** (default — they probably ran the skill by accident).
- **Re-bootstrap from scratch** (overwrites their answers — confirm explicitly).

A partial bootstrap (some `<TODO>` markers remain in either file) is fine to resume — proceed without prompting.

## Step 2 — interview

Use AskUserQuestion. Group related questions in a single call when their options don't depend on each other.

### Round 1 — the product

One AskUserQuestion call with three free-text-style questions framed as 2–3 options each plus the implicit "Other" the user can type into:

- **Product name** — give two suggested-style examples ("Birdwatcher", "ChatPilot Pro") so the user types their own via Other. Header: "Product name".
- **Description** — one paragraph: what it is, who it's for, why it exists. Header: "Description".
- **Success metric** — one line, ideally measurable, defining what "this worked" looks like 6 months out. Header: "Success metric".

(For the description and success-metric prompts, the realistic flow is the user picks "Other" and writes their own — that's expected.)

### Round 2 — the team

One AskUserQuestion call with:

- **GitHub owner** — the org/user that owns this bus repo and the AoD vault that scopes write access. e.g. `BinaryBourbon`. Header: "GitHub owner".
- **Vault name** — the AoD vault in `aod-specs/vaults/` holding a write-scoped `GITHUB_TOKEN` for that owner. e.g. `binarybourbon`. If the user doesn't have one yet, tell them to seed one per [`aod-specs/OPERATIONS.md` § Seed a vault for the project](https://github.com/jhgaylor/aod-specs/blob/main/OPERATIONS.md#seed-a-vault-for-the-project-once-per-project) before running captain-picard. Don't block bootstrap on it — the vault can be created later. Header: "Vault name".
- **Specialists** (multiSelect) — which fleet members will this team use? Default-on: `customer-researcher`, `growth-marketer`, `designer`, `general-purpose-engineer`, `pr-reviewer`, `release-validator`, `reliability-engineer`, `product-analyst`. The user deselects ones they don't expect to use. Header: "Specialists".

### Round 3 — gates

One AskUserQuestion call:

- **Gate ladder** (single-select):
  - "Default G0–G3 ladder" (Recommended) — uses the canonical four gates (direction, narrative, plan, ship). Description should preview the four gate titles.
  - "Customize" — user defines their own gates. If chosen, follow up with another AskUserQuestion asking for each gate's title until the user signals they're done.
  - "Single G0 only (lightweight)" — for very small experiments where one decision point is enough.

If the user customizes, capture each gate as `G<n>: <one-line decision>`.

### Round 4 — initial roadmap

One AskUserQuestion call:

- **First slice** (single-select):
  - "phase-0-framing → customer-researcher" (Recommended) — the canonical first slice.
  - "Skip framing — go straight to building" — only if the product is already framed (e.g., the user has a clear PRD already and just wants captain-picard to dispatch engineering work).
  - The user can type their own first-slice description via Other.

## Step 3 — fill the templates

Use the Edit tool (NOT Write — preserve everything outside the `<TODO>` blocks).

### `OPERATING_MODEL.md`

Replace each `<TODO: ...>` placeholder:

- `## Product` block — name, description, success metric from Round 1.
- `## Roles` block — replace the three placeholder bullets with one bullet per selected specialist from Round 2. The "(Default fleet — keep what applies, drop the rest:)" reference list below it should be **deleted** since the team has now committed to a specific subset. Keep the one-line "when to dispatch" hint for each selected role from the reference list (paraphrase if needed).
- `## Gates` block — replace the four `<TODO>` lines with the chosen ladder. The "(Default ladder for a new product:)" block below it should be **deleted** for the same reason.
- `## Working agreements` block — leave the four canonical rules. Replace the trailing `<TODO>` with a brief note from the user if they offered any product-specific agreements during the interview, otherwise delete the placeholder line.

### `ROADMAP.md`

- `## Next` block — replace the placeholder `<TODO: ...>` line with the first-slice choice from Round 4. Keep the canonical `phase-0-framing` entry if the user picked the default; replace it if they chose otherwise.
- `## Gated` block — replace the trailing `<TODO: ...>` line. Seed Gated with G0 (and any other gates the user defined). One line per gate.

### `README.md`

The template README explains the template itself — it's not what you want sitting at the root of a real product repo. Replace it with a minimal README seeded from Round 1's product name and description:

```markdown
# <product name>

<one-paragraph description>

This repo is the bus for the [`captain-picard`](https://github.com/jhgaylor/aod-specs) Agent on Demand orchestrator. See `OPERATING_MODEL.md` for how the team operates and `ROADMAP.md` for what's open.
```

## Step 4 — confirm and commit

Show the user a one-paragraph summary: product name, specialist count, gate count, first slice.

AskUserQuestion: what next?

- **Commit + push** (Recommended) — `git add OPERATING_MODEL.md ROADMAP.md README.md && git commit -m "bootstrap: seed operating model + roadmap" && git push`.
- **Commit only** — same commit, no push (user wants to review or rebase locally).
- **Stop without committing** — user wants to hand-edit before committing.

## Step 5 — point them at the next step

After the commit (or after step 4 if they declined), tell the user:

> The bus repo is ready. Next:
>
> 1. Make sure your AoD vault `<vault-name-from-round-2>` exists in `aod-specs/vaults/` with a write-scoped `GITHUB_TOKEN` for `<owner-from-round-2>` (`make apply` in aod-specs after adding it).
> 2. Run captain-picard:
>    ```bash
>    aod run captain-picard --vault <vault-name> -p \
>      "repo_url=<this-repo's-github-URL>
>       vault_name=<vault-name>
>       operating_doc_path=OPERATING_MODEL.md
>
>       begin phase 0 per ROADMAP.md."
>    ```

Substitute the actual values from the interview into the example.

## What NOT to do

- **Don't dispatch anything.** Bootstrap only seeds files. captain-picard does dispatching.
- **Don't write real ADRs.** `decisions/0001-template.md` stays untouched — it's the template, not a decision. Real ADRs accumulate as the team works.
- **Don't create `plan/`.** The orchestrator creates that on first dispatch.
- **Don't customize the captain-picard agent prompt.** That lives in `aod-specs/agents/teams/captain-picard/captain-picard.yml`. If the team's process diverges from what the agent expects, change `OPERATING_MODEL.md` here, not the agent.
- **Don't edit or delete `PREREQUISITES.md`.** That's a survives-the-bootstrap reference for one-time aod-specs setup; it's product-agnostic and stays put across every bootstrap.
- **Don't make up vault details.** If the user can't tell you the owner or vault name confidently, leave plausible placeholders and tell them to fix before running captain-picard.
