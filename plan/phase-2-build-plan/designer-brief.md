## Context

G1 locked. Fountain is a hosted multi-tenant platform (API + Phoenix LiveView dashboard + CLI) for managing sandboxed AI coding agents. The press release at `plan/phase-1-press-release/press-release.md` defines the narrative. The product description is in `OPERATING_MODEL.md`. The Option B scope is in `decisions/0003-direction-option-b-api-ui-onboarding.md` and `plan/phase-0-framing/scope-comparison.md`.

The reference implementation is `jhgaylor/aod-ex` (see `decisions/0002-aod-ex-as-reference.md`). Its LiveView UI covers Environments, Agents, Conversations, and Vaults for a single operator. You are designing the multi-tenant version of those same surfaces plus the onboarding flow and log viewer.

## Task

- Produce `plan/phase-2-build-plan/ux-spec.md`: a UX spec covering the key user-facing flows for Fountain's dashboard.
- Required flows to specify (each as a numbered step sequence + key decisions/states):
  1. **Onboarding wizard** — sign-up → email verify → first environment → first agent → first conversation
  2. **Agent configuration** — create/edit agent: model, system prompt, runtime, skills, environment, MCP servers
  3. **Vault management** — create vault, add/edit secrets, select vault when starting a conversation
  4. **Conversation + log viewer** — start conversation, real-time SSE log stream, multi-turn follow-up, terminate
  5. **Account/settings** — API key management, usage summary, plan/billing status
- For each flow, note what the engineer needs to support from the API side (e.g. SSE endpoint shape, pagination).
- Do not produce visual mockups or HTML — prose step-sequences and state descriptions are sufficient.

## Acceptance

- `plan/phase-2-build-plan/ux-spec.md` exists in a PR against `main` on `BinaryBourbon/fountain`.
- All five flows are covered with enough detail that an engineer can derive API requirements from them.
- PR description states what UI decisions are load-bearing for engineering and what is left flexible.

## Out of scope

- Do not write HTML, CSS, or code.
- Do not design admin/support tooling (scoped to post-launch).
- Do not design org/team features (deferred per `decisions/0003`).
- Do not modify `OPERATING_MODEL.md`, `ROADMAP.md`, or `decisions/` files.
