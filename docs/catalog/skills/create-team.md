# create-team

> A five-question conversation that proposes a roster of teammates, creates
> them, and hands them over.

## At a glance

| | |
|---|---|
| Bundled | Yes, in every sandbox |
| Declared by | Nobody. It is always present |
| Source | `apps/fountain/priv/sprite_skills/create-team/SKILL.md` |
| Triggered by | `/create-team`, or asking a teammate to help set up a team |

## What happens when you run it

Say `/create-team` to any teammate, or ask it what the team should look like.

**It asks at most five questions**, one at a time, with a default offered in
each so "yes" is a complete answer.

1. What should the team get done?
2. Which repos or services are in scope, and which need a token?
3. How many teammates, roughly? Usually two to five, and a lead is worth it
   past three.
4. Any brain preference? It checks `GET /api/catalog` for models and your
   inference credentials for which providers you actually have a key for, and
   will not propose one you cannot run.
5. What names? Role names such as `repo-maintainer`, or a themed set.

**Then it proposes.** A table of name, brain, one-line role, and the first
thing it would send each teammate.

**It creates nothing before you say yes.**

**Then it hands over.** The roster as created, who to message for what, one
concrete first message each, and a note that teammates can reach each other.

## What it creates

For each teammate, an [Agent](../../concepts/agent.md) and then a
[team membership](../../concepts/teammates.md), which opens that agent's one
ongoing conversation and provisions its sandbox.

Everything it sets is editable afterwards from the team app. Brain, role and
name are not decisions you are stuck with.

## Its own rules

The skill constrains itself in four ways worth knowing, because they are the
difference between a helpful flow and a destructive one.

- One question at a time, and it stops asking as soon as it can propose.
- Never create before a confirmation. Never delete or rename anything.
- Never paste tokens into prompts, descriptions or messages.
- On a name conflict it adds a suffix and says so. On a missing credential it
  names the provider and where to add the key.

## Limits

**It only adds.** It will not remove a teammate, rename one, or reorganise an
existing team.

**It needs inference credentials already in place.** It checks first and tells
you what is missing rather than creating agents that cannot run.

**Every teammate it creates provisions a sandbox.** A roster of five is five
machines. See
[Change sandbox lifetimes](../../guides/operate/sandbox-lifetime.md).

## Related

- [Agents as teammates](../../concepts/teammates.md), what it is building.
- [About agents](../../concepts/agent.md).
- [Skills](index.md).
