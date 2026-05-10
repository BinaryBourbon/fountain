## Context

All functional LiveViews are merged into `main`: onboarding wizard, log viewer, billing UI, API keys UI, admin UI, and the scoped versions of agents/environments/vaults/conversations. The UX spec is at `plan/phase-2-build-plan/ux-spec.md`. The engineering plan §6.5 specifies the design system scope. A parallel `phase-3-release-validation` slice is running read-only tests — no file conflicts expected.

This is the final pre-G3 design pass. Functional correctness is already done; your job is visual consistency, dark mode, and component quality across all surfaces.

## Task

Branch `phase-3-design-pass` from `main`.

- **Design system tokens** per engineering plan §6.5:
  - Define light + dark mode colour tokens in `assets/css/tokens.css` using CSS custom properties. Reference `data-theme="dark"` on `<html>` for the dark variant. Provide at minimum: brand primary, surface/background levels, border, text (primary, secondary, muted), status colours (success/warning/error/info), and code-block background.
  - Extend `tailwind.config.js` to reference the tokens so Tailwind utilities pick them up.
  - Add a theme toggle: a button in the nav that sets `data-theme` on `<html>` and stores the preference in `localStorage` (JS hook). Wire to `users.theme_preference` on the server via a `PATCH /api/settings/theme` endpoint so the preference survives login on a new device.
- **Component library** — extract reusable function components or LiveView components into `lib/fountain_web/components/`:
  - `<.button>` (primary, secondary, danger, ghost variants; loading spinner state).
  - `<.badge>` (status badges: pending/grey, starting/blue, ready/green, terminated/neutral, failed/red — matching conversation status values).
  - `<.modal>` (accessible: focus trap, `Escape` to close, backdrop click to close).
  - `<.flash>` (info, success, warning, error; auto-dismiss after 5 s).
  - `<.table>` (sortable header optional, empty-state slot, pagination slot).
  - `<.code_block>` (monospace, syntax-neutral; used by log viewer output lines).
  - `<.form_field>` (label + input + inline error message wrapper).
- **Apply components** across all LiveViews: replace ad-hoc HTML with the component library. Confirm WCAG AA contrast ratios for all text/background token combinations in both light and dark modes.
- **Accessibility sweep**: every interactive element has a visible focus ring; all `<button>` elements have accessible labels; modals trap focus; the log viewer auto-scroll “Jump to bottom” button is keyboard-accessible.
- **Nav and layout**: implement a consistent sidebar nav linking to: Conversations, Agents, Environments, Vaults, Settings (API keys, billing). Admin nav item visible only when `current_user.role == "admin"`. Mobile: sidebar collapses to a hamburger menu.

## Acceptance

- PR `phase-3-design-pass` against `main`.
- `mix compile` and `mix test` pass (no functional regressions).
- Light and dark mode both render without unstyled fallbacks — verify by toggling `data-theme` in the browser.
- All six component types exist in `lib/fountain_web/components/` and are used in at least one LiveView.
- Conversation status badges use the correct colour for each of the five status values.
- Modal focus trap: Tab cycles within the modal; Escape closes it.
- No inline `style=` attributes introduced (all styling via tokens and Tailwind).

## Out of scope

- Do not change any functional LiveView logic, context calls, or API endpoints.
- Do not implement org/team features or the usage chart (deferred).
- Do not implement the full onboarding marketing/landing page (`/`) — a minimal placeholder is sufficient at G3.
