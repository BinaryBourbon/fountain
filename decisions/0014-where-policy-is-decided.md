# 0014 — Where policy is decided

**Status:** Proposed. **Nothing described here is built.** No `Fountain.Policy`
module, `Subject` struct, guardrail test or Credo check exists today; the
"Migration" section is the plan for building them, and the PR that lands each
stage removes its caveat here. Read the "Context" section as a description of
the system as it stands, and everything under "Decision" as an argument about
what should replace it.

## Context

Fountain decides "may this happen" in six unrelated places, each with its own
vocabulary for saying no:

| Mechanism | Where | How it refuses |
|---|---|---|
| Router pipelines | `:require_full_scope`, `:require_key_management`, `:require_admin_api` | JSON 403 + `reason: "insufficient_scope"` |
| LiveView `on_mount` | `FountainWeb.Live.Hooks` | `redirect` (login, billing) vs `push_navigate` (non-admin) |
| Per-event allowlist in a view | `conversations_live/show.ex:166` | flash, no halt |
| Context `with` chains | `conversations.ex:913`, `:1135`, `:1208` | `{:error, atom}` |
| GenServer backstop | `conversation_server.ex:2059` | `{:error, atom}` |
| Naming convention + Credo | `_unsafe_*`, check `FN0001` | compile-time warning |

None of these is wrong on its own, and the denial *rendering* is already in one
place and carefully reasoned: `FountainWeb.FallbackController` decides 404 over
403 for `vault_not_found` so ids cannot be probed, 429 over 402 for quota
because the caller can clear it without paying, 410 for a terminated
conversation so clients stop retrying. That part works.

What does not work is that the **rules themselves are unwritten**, so they get
rediscovered one incident at a time. The pair
`Accounts.check_not_suspended/1` + `Billing.check_active/1` now appears at four
call sites — `conversations.ex:913` (fresh start), `:1135` (the reuse arm of a
wake), `:1208` (the provision arm of a wake), and `conversation_server.ex:2059`
(every turn) — and each one carries a comment explaining why *it too* needs the
check, each citing a different bug:

- #313 — a live `ConversationServer` outlives the subscription state it started
  under, so an expired trial bought up to 24h of continued service per sandbox.
  Fixed by adding `turn_gate/1`.
- #313 again — the reuse arm of a wake provisions nothing, so it skipped the
  gates entirely and a canceled user could restart against a live sprite.
- #330 — quota was check-then-insert, so N concurrent requests at the cap each
  passed and provisioned N-1 sprites over it. Fixed with an advisory lock.
- #399 — the LiveView composer is hidden for lapsed accounts, but events can
  still be sent by hand, so hiding the button was never the gate.

Four separate discoveries of one rule: *anything that spends must check
suspension and subscription, at the moment it spends.* Written down once and
enforced, the second, third and fourth would have been mechanical.

The same shape is visible in what the current mechanisms **cannot express**. A
`sprite`-scoped key (`api_key.ex`) is a flat list of strings with no reference
to the conversation that owns it, so "this sprite may act on its own
conversation tree" is not a sayable rule — the scope either permits the whole
tenant resource surface or none of it. That is a deliberate trade today
(spawning sub-agents from inside a sprite is supported), but it is a trade the
system was forced into by the shape of the mechanism rather than chosen.

ADR 0013 settled the equivalent problem for the audit trail, and the campaign
behind it (#540) is the direct precedent for everything below: a rule stated
once, a closed vocabulary, a guardrail test, and an ADR to push against.

## Decision

### 1. Mutations authorize inside the context function, not at the caller

The same rule ADR 0013 §1 established for auditing, for the same reason: a
function that spends, exposes or changes tenant-owned state decides its own
admissibility, so the UI, the API, background workers and any future surface
are covered by construction rather than by each caller remembering.

The corollary is the part worth stating explicitly, because it is what the
current system gets wrong:

> **Every surface may deny early for UX. Only the context may permit.**

Router pipelines, `on_mount` hooks and the `@spend_events` guard do not go
away. They demote to *affordances* — redirect before rendering a page the user
cannot use, hide a composer that would fail, disable a button. None of them is
load-bearing, and removing any one of them changes what the user sees but never
what the user can do. #399 is the whole argument: a hidden composer is a
courtesy, not a gate.

```elixir
# in the context — enforcement
def start_conversation(attrs, opts \\ []) do
  with {:ok, subject} <- Policy.Subject.fetch(opts),
       :ok <- Policy.authorize(:"conversation.start", subject, attrs),
       ...
end

# at the surface — affordance only
<.button disabled={not Policy.permitted?(:"conversation.prompt", @subject, @conv)} />
```

`permitted?/3` runs the same rules side-effect-free for rendering. It replaces
the `@subscription_active` assign, which today is a *second* evaluation of the
billing gate that can drift from the one that enforces.

### 2. One subject, shared with the audit trail

Policy takes a `%Fountain.Policy.Subject{}`, never a bare `%User{}`:

```elixir
%Subject{
  user: %User{},
  via: :ui | :api | :sprite | :admin | :system,
  scopes: ["sprite"],
  conversation_id: "…"   # present when via: :sprite
}
```

This is not a new concept — it is the promotion of one that already exists in
shadow form. `FountainWeb.Audited.attribution/2` derives exactly this principal
from a `%Plug.Conn{}` or a LiveView socket, and reads `key.scopes` at
`audited.ex:135` to tell `sprite` from `api`. Today that derivation feeds the
audit trail only, while `RequireFullScope` reads the same `scopes` field for an
unrelated purpose a few plugs away.

Unifying them means the actor vocabulary ADR 0013 closed (`self`, `ui`, `api`,
`sprite`, `admin`, `admin:<id>`, `system:<worker>`) becomes the *policy* subject
vocabulary too, and a mutation cannot be authorized without also being
attributable. It also removes the bare-`"system"` defect class structurally:
0013 has to describe `"system"` as "a defect signal, not a value" precisely
because `attribution/2` can produce a principal-less actor. A `Subject` that
cannot be constructed without a principal makes that unrepresentable rather
than merely discouraged.

`conversation_id` on the subject is what makes sprite confinement *sayable*.
This ADR does not decide to confine sprite tokens — that is a separate call
with real workflow consequences. It decides that the question stops being
unaskable.

### 3. The action vocabulary is the audit vocabulary

Actions are atoms matching the audit action strings one-for-one:
`:"conversation.start"`, `:"conversation.prompt"`, `:"api_key.mint"`,
`:"vault.secret.write"`, `:"account.suspend"`.

`audit_guardrail_test.exs` already enumerates roughly twenty-five context
mutations. Making "what may happen" and "what happened" the same closed list is
the largest single win available here: a new action cannot exist unauthorized
*or* unaudited, and an operator reading the trail is reading the same names the
policy is written in. Adding an action is an amendment to this ADR and 0013
together, not a judgement call at a call site.

### 4. Denials are semantic; rendering stays at the surface

`authorize/3` returns `:ok` or `{:error, %Policy.Denial{}}`:

```elixir
%Denial{reason: :subscription_required, action: :"conversation.prompt", details: %{}}
```

**No HTTP in the denial.** The reason list moves into the policy module; the
rendering stays exactly where it is. `FallbackController` keeps every status
code it has already argued its way to, a `Policy.Live` helper does the
redirect-vs-flash split that `Hooks` does today, and the CLI renders the same
reasons as prose. One reason list, three renderers.

This is deliberately the opposite of folding the response shape into the rule.
The 404-not-403 choice for `vault_not_found` is a fact about the HTTP surface's
threat model, not about whether the vault may be attached; a CLI or a LiveView
has no equivalent decision to make and should not inherit one.

### 5. What the policy engine does not own

Two things stay where they are, and this ADR exists partly to say so before
someone tidies them in.

**Query-level tenant scoping stays.** `Agents.get_agent(id, user_id)` is
strictly stronger than authorizing a row after loading it: a row that was never
selected cannot leak through a rendering bug, a log line or an error message.
Replacing it with `authorize(:"agent.read", subject, agent)` would be a
downgrade dressed as consolidation. The `_unsafe_` prefix, the ownership-comment
rule and Credo `FN0001` are the mechanism for tenant scoping and remain so. The
policy engine decides what happens *after* the row is legitimately in hand:
`allowed_vault_ids` (`conversations.ex:1095`), spend gates, scopes, admin
surfaces.

**Rate limiting stays in the plug.** `FountainWeb.Plugs.RateLimit` is a per-IP
abuse control, explicitly not a per-tenant entitlement (its own moduledoc says
so). It runs before authentication by design (#316) — before there is a subject
to authorize.

### 6. The rule is enforced, not documented

Unenforced, this decays exactly the way pre-#540 auditing did. Three
mechanisms, each of which has already been proven in this repo:

- **`policy_guardrail_test.exs`**, modelled on `audit_guardrail_test.exs`:
  every context mutation routes through `authorize/3`, or sits on a documented
  exclusion list with a reason.
- **Credo check `FN0002`**, a sibling of `FN0001`: a context mutation that
  neither authorizes nor carries an exemption comment fails `--strict`.
- **A decision-table snapshot test.** A golden file of
  action × subject-kind × account-state → decision. This is the one thing an
  external policy engine genuinely sells you — introspectability — and a
  snapshot buys it for the cost of one test file. A policy change becomes a
  reviewable diff in a table instead of a `with` clause nobody notices.

## Consequences

- The spend rule is stated once. A new provisioning path is covered by the
  rule rather than by whoever reviews it noticing the four existing copies.
- The three-way drift risk between `Hooks`, `conversation_controller.ex:710`
  and `conversations.ex` disappears: they call one function.
- Policy becomes reviewable by someone who does not read Elixir call graphs —
  the decision table is the artifact to argue about in a security review.
- `%Subject{}` threading is real work at every call site, and is the bulk of
  the cost. It is also the part that pays twice, since audit attribution rides
  the same struct.
- Adding an action is now an ADR amendment. This is intended friction; it is
  the same friction 0013 put on the actor vocabulary.
- The affordance layer becomes *provably* non-load-bearing, which means it can
  be changed freely — a UI refactor cannot open a hole.
- Denials from a self-hosted instance with billing disabled must stay
  indistinguishable from "never gated", per #524. The rule set has to keep
  `Billing.enabled?/0` as a short-circuit rather than a reason.

## Alternatives considered

- **An external policy engine (OPA/Rego, Cedar), as a sidecar or NIF** — the
  inputs here are live Postgres state: active sandbox count, subscription
  status, `allowed_vault_ids`, suspension. An external evaluator either reads
  stale data or you do the DB round trip to build its input, at which point the
  engine is a serializer with a network hop. External engines pay off when
  policy is authored by people who do not deploy the app; that is not the
  situation. Rejected.
- **Bodyguard or LetMe** — both return a bare `{:error, :unauthorized}` shape,
  and the entire value of this work is in *which* denial: 402 with an upgrade
  URL, 403 with no recourse, 429 with a count and a limit, 410 for good. Wrapping
  either to carry structured denials is more code than the ~200 lines the rules
  need directly, in a less idiomatic shape. Rejected.
- **Keep enforcement at the edge, and make the edge exhaustive** — a plug and
  an `on_mount` for every rule, applied to every route. This is what the system
  approximates today. It fails on every non-HTTP door: the queued initial
  prompt a wake delivers as a cast, the rehydrator, `verify_lifecycle`. #313
  was exactly this failure. Rejected; it is the bug, not the fix.
- **Fold tenant scoping into the engine so there is one authorization concept** —
  tempting symmetry, real regression. See §5. Rejected.
- **A `Repo` hook or Ecto callback that authorizes every write** — catches every
  write and can name none of them. The same argument 0013 makes against auditing
  in a `Repo` hook: `:"conversation.prompt"` denied for `:subscription_required`
  is the useful statement, and a callback sees an insert into `turns`. Rejected.

## Migration

Five stages, each independently shippable and each behavior-preserving except
where noted.

1. **`Policy.Subject` + `Subject.from(conn | socket | worker)`**, unified with
   `Audited.attribution/2`. No policy yet, no behavior change. Delivers the
   principal-less-actor fix on its own.
2. **`Fountain.Policy` + `Policy.Denial`**, with rules for
   `:"conversation.start"` and `:"conversation.prompt"` only. Port the four
   suspension/billing/quota sites to it. Four explanatory comments collapse
   into one rule with one comment. `FallbackController` gains a `%Denial{}`
   clause and keeps every existing one.
3. **`permitted?/3`** replaces `@subscription_active` and `@spend_events`.
   First stage with user-visible surface area; the read-only contract from #505
   must be preserved exactly (terminate, interrupt and delete stay permitted —
   they stop spend or remove data).
4. **Scopes into the rules.** The three scope plugs become thin wrappers over
   `authorize/3`. Sprite confinement becomes expressible; whether to adopt it
   is a separate decision with its own ADR.
5. **Guardrail test, `FN0002`, decision table.** Status here flips to Accepted,
   and the caveat at the top of this file is removed.
