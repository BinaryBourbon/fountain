# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Now

_(empty — orchestrator fills this on dispatch, with `<slice> — <role> (conv <id>)` per entry.)_

## Next

- **phase-0-framing** — produce a side-by-side framing of candidates and decide direction at G0. Dispatch as `customer-researcher`.

## Gated

- **G0** — Pick a product direction from the framing PR.
- **G1** — Press-release narrative locked.
- **G2** — Architecture and engineering plan locked.
- **G3** — Ready to ship — go/no-go for public launch.
