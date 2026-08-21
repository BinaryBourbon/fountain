# Skills

A skill is a `SKILL.md` written into the sandbox, which the runtime reads to
learn a capability. Skills are declared on an [Agent](../../concepts/agent.md).

## Bundled in every sandbox

These two are written into **every** sandbox, whatever an agent declares.

| Skill | What it does |
|---|---|
| [fountain](fountain.md) | Gives the agent Fountain's own API, so it can spawn and stream sub-conversations |
| [create-team](create-team.md) | A five-question flow that builds the user's team. Answering `/create-team` runs it |

## Declaring your own

Two forms, and they behave differently.

**Inline.** The whole file, written directly to
`<skills_root>/<name>/SKILL.md`.

```yaml
skills:
  - name: house-style
    content: |
      ---
      name: house-style
      description: Our commit message and PR conventions.
      ---
      # House style
      ...
```

**From GitHub.** Installed on the sandbox with the
[skills.sh](https://skills.sh) CLI.

```yaml
skills:
  - source: BinaryBourbon/fountain-api-skill
    ref: v1.2.0        # optional: a tag, branch or sha
    name: fountain-api # optional: rename on install
```

Without a `ref`, the repository's default branch is resolved **at spawn time**.
Two conversations from the same agent, a week apart, can install different
code. Pin a `ref` for anything you depend on.

## Two things about how they land

**Skills mount before the network policy locks the sandbox down.** GitHub
installs need npm and github.com, so they happen first. A `limited` environment
that allowlists neither still gets its skills, and this ordering is why.

**GitHub installs run before inline writes.** The install is a blocking exec,
which doubles as the readiness gate the file-write path needs anyway.

## The path depends on the runtime

Each runtime declares its own skills root and its own skills.sh agent name, so
the same declaration lands in a different place depending on `runtime`. See
[Runtimes](../runtimes/index.md) for the table.

## Not here yet

There is no catalog of third-party skills. Anything on GitHub that ships a
`SKILL.md` works, and Fountain does not curate a list.

## Related

- [About agents](../../concepts/agent.md), where `skills` is declared.
- [Runtimes](../runtimes/index.md), for where a skill lands on disk.
- [Agents as teammates](../../concepts/teammates.md), which
  [create-team](create-team.md) builds.
