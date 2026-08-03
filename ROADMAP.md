# Roadmap

The captain-picard orchestrator reads this every cycle and writes the conversation id of each dispatched slice into "Now." Keep this file under one screen — if it grows, kill or defer something.

## Now

_(empty — Fountain has launched. Waiting for post-launch data before dispatching next work.)_

## Next

- Monitor for early user issues (reliability-engineer on standby)
- product-analyst: instrument PostHog/Honeycomb and establish WAU baseline
- growth-marketer: launch announcement and first growth experiment
- Post-launch backlog: NC-6 (standardise `onboarding_completed_at` vs
  `onboarding_state`) — the last one open. NC-1 (dark mode), NC-4/NC-5
  (billing test coverage) and NC-9 (`usage_events` user-deletion handling)
  are built and tested; see ADR 0007's 2026-08-03 addendum.

## Gated

- **Post-G3 gate** — Review WAU at 30 days. If traction, unlock org/team features phase.
