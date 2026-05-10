# captain-picard-template

Bus-repo template for the [`captain-picard`](https://github.com/jhgaylor/aod-specs/blob/main/agents/teams/captain-picard/captain-picard.yml) Agent on Demand orchestrator.

`captain-picard` is the project-agnostic product engineering team lead from the [`jhgaylor/aod-specs`](https://github.com/jhgaylor/aod-specs) fleet. It expects every product it works on to seed three files at the bus-repo root:

- `OPERATING_MODEL.md` — the product, the team's roles, and the gate ladder.
- `ROADMAP.md` — Now / Next / Gated lanes.
- `decisions/` — ADRs as they accumulate.

This template seeds those with `<TODO>` placeholders and ships an interactive `/bootstrap` skill for Claude Code that walks you through filling them in.

## Use it

> **First time?** This template needs `captain-picard` already provisioned in your Agent on Demand instance. If you haven't done that, do the one-time setup in **[PREREQUISITES.md](PREREQUISITES.md)** first.

1. Click **Use this template** on GitHub (top-right of the repo page) → create your bus repo under whatever owner runs the product (e.g. `BinaryBourbon/birdwatcher`).
2. Clone it locally and run `claude` in the working tree.
3. Type `/bootstrap`. The skill interviews you (product, owner, vault, specialists, gates, initial slice), fills the templates, and offers to commit and push.
4. Run captain-picard against the bus repo:

   ```bash
   aod run captain-picard --vault <project-vault> -p \
     "repo_url=https://github.com/<owner>/<repo>
      vault_name=<project-vault>
      operating_doc_path=OPERATING_MODEL.md

      begin phase 0 per ROADMAP.md."
   ```

## What's in here

```
.
├── OPERATING_MODEL.md       # template — fill via /bootstrap
├── ROADMAP.md               # template — fill via /bootstrap
├── decisions/
│   └── 0001-template.md     # ADR template, copy when writing a real ADR
├── .claude/skills/bootstrap/
│   └── SKILL.md             # the /bootstrap skill
├── PREREQUISITES.md         # one-time aod-specs setup — survives /bootstrap
└── README.md                # this file (replaced post-bootstrap with your product's README)
```

## After bootstrapping

The orchestrator's `plan/<slice>/<role>-brief.md` files appear when captain-picard dispatches its first specialist — you don't seed `plan/` manually.

You should replace this README with one describing your actual product before the bus repo gets used by humans. The template `README.md` is meant to be deleted; the operating model and roadmap stay.
