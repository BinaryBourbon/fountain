# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Now

_(empty — orchestrator fills this on dispatch, with `<slice> — <role> (conv <id>)` per entry.)_

## Next

- **phase-0-framing** — start from [`jhgaylor/aod-ex`](https://github.com/jhgaylor/aod-ex) (the single-tenant predecessor) and frame what has to change for the multi-tenant target user. Produce a side-by-side comparison of candidate scopes and decide direction at G0. Dispatch as `customer-researcher`. See [`decisions/0002-aod-ex-as-reference.md`](decisions/0002-aod-ex-as-reference.md).

## Gated

- **G0** — Pick a product direction from the framing PR.
- **G1** — Press-release narrative locked.
- **G2** — Architecture and engineering plan locked.
- **G3** — Ready to ship — go/no-go for public launch.
