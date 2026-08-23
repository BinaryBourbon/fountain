defmodule Fountain.Plans do
  @moduledoc """
  The plan catalog: what a tenant's subscription tier entitles them to.

  Fountain bills one flat monthly price per tenant (ADR 0006). Until #798 that
  price was a single number and the only entitlement — the concurrent-sandbox
  cap — was a per-user column an operator hand-set, tied to nothing anybody
  paid. This module is the other half: a small, closed set of tiers that
  differ on the axis Fountain already enforces, so the cap a tenant gets
  follows from the price they pay.

  ## The axis

  Concurrent sandboxes, and only that. It is the one thing that is both a real
  cost to Fountain (capacity on the shared provider account, ADR 0005/0018)
  and legible to a customer without a usage meter. The tiers are still priced
  on it; the turn-hour allowance below is an amount of work *inside* a tier,
  not a second axis to sell on.

  ## Included turn hours

  `included_turn_hours` is derived, not chosen per tier: **20 turn hours per
  concurrent sandbox the plan allows**, so Solo's 5 slots carry 100 hours and
  Scale's 40 carry 800. Deriving it keeps the ladder on one axis — a plan
  cannot end up with more capacity and less work to do with it.

  A *turn* hour is time with a prompt actually in flight
  (`Fountain.Billing.SandboxUsage`'s `busy_seconds`), not wall-clock sandbox
  time. The distinction is the whole point: a sandbox left running overnight
  with nobody prompting it burns `active_seconds` and no allowance, so the
  meter measures work rather than forgetfulness. Hours on a tenant's own
  runner (ADR 0022) do not count either — Fountain pays nothing for them.

  **Nothing enforces this yet.** `Fountain.Billing.turn_hour_allowance/2`
  reports used against included and every surface displays it; no code path
  refuses anything because of it. The overage shape — post-paid or prepaid
  credits — is deliberately still open (#1016 step 4), to be decided with a
  cycle of real numbers in hand.

  ## The catalog

  | Plan | Concurrent | Turn hours | Teammate contacts | Price |
  |---|---|---|---|---|
  | `solo` | 5 | 100 | 1 | $29/mo |
  | `team` | 15 | 300 | 3 | $79/mo |
  | `scale` | 40 | 800 | 10 | $199/mo |
  | `legacy` | 15 | 300 | 3 | $29/mo (closed) |

  `legacy` is the flat price every account bought before the tiers existed.
  It is pinned to the old `STRIPE_PRICE_ID`, carries `team`'s capacity so that
  nobody lost anything at the changeover, and is `public?: false` — it is
  never offered, only left alone or upgraded away from.

  ## Teammate contacts are a ceiling, not an allowance

  An AgentMail inbox and an AgentPhone number cost real money per teammate per
  month, so they are **billed as an add-on** — a second subscription item whose
  quantity is the tenant's contact count (`Fountain.Billing.sync_contact_addon/1`).
  Any plan can buy them. `team_contacts/1` is therefore an abuse ceiling rather
  than an entitlement: it bounds what a single account can provision in one
  burst if the quantity sync is failing, which is exactly the window in which
  Fountain would be paying for numbers it is not charging for.

  ## Resolution, and self-hosting

  `resolve/1` takes a user, a slug or `nil` and always returns a plan. A `nil`
  `users.plan` means "whatever this deployment's default is" —
  `config :fountain, :default_plan` (`DEFAULT_PLAN`), itself defaulting to
  `solo`. That is the only knob a self-hoster needs: they pay their own
  provider bill, so `DEFAULT_PLAN=scale` lifts the cap for every account at
  once without inventing a billing relationship.

  An unknown slug resolves to the default rather than raising. A row that
  somehow holds a retired slug should tighten to a known plan, not take down
  every request that reads it.

  ## Where the numbers are enforced

  * `Fountain.Quotas.sandbox_limit/1` — the concurrency cap, with
    `users.sandbox_limit_override` winning when set.
  * `Fountain.Team.Comms.provision_contact/4` — the contact ceiling.

  Price ids come from config, never from here: see `price_id/1`. The cents in
  the catalog are display copy for the marketing page and the plan picker, and
  `mix fountain.verify_plans` checks them against what Stripe actually charges.
  """

  defstruct [
    :slug,
    :name,
    :tagline,
    :monthly_cents,
    :concurrent_sandboxes,
    :included_turn_hours,
    :team_contacts,
    :order,
    public?: true
  ]

  @type t :: %__MODULE__{}

  # Plain maps, not structs: a module attribute cannot hold a struct of the
  # module that is defining it. `all/0` is what turns these into `%Plans{}`,
  # and with four of them the cost of doing so per call is not worth caching.
  #
  # `included_turn_hours` is 20 per concurrent slot, written out per plan
  # rather than computed, so the catalog stays a table you can read every
  # entitlement off. `plans_test.exs` asserts the ratio, so breaking it for a
  # future plan is a deliberate act rather than a typo.
  @plan_specs [
    %{
      slug: "solo",
      name: "Solo",
      tagline: "One person, a handful of agents at a time.",
      monthly_cents: 2_900,
      concurrent_sandboxes: 5,
      included_turn_hours: 100,
      team_contacts: 1,
      order: 1
    },
    %{
      slug: "team",
      name: "Team",
      tagline: "A standing team of agents, working in parallel.",
      monthly_cents: 7_900,
      concurrent_sandboxes: 15,
      included_turn_hours: 300,
      team_contacts: 3,
      order: 2
    },
    %{
      slug: "scale",
      name: "Scale",
      tagline: "Fleet-sized fan-out, without asking first.",
      monthly_cents: 19_900,
      concurrent_sandboxes: 40,
      included_turn_hours: 800,
      team_contacts: 10,
      order: 3
    },
    %{
      slug: "legacy",
      name: "Legacy",
      tagline: "The original flat plan, at Team capacity.",
      monthly_cents: 2_900,
      concurrent_sandboxes: 15,
      included_turn_hours: 300,
      team_contacts: 3,
      order: 0,
      public?: false
    }
  ]

  @slugs Enum.map(@plan_specs, & &1.slug)
  @sorted_specs Enum.sort_by(@plan_specs, & &1.order)
  @fallback_default "solo"

  @doc "Every plan in the catalog, cheapest first, `legacy` before them all."
  @spec all() :: [t()]
  def all, do: Enum.map(@sorted_specs, &struct!(__MODULE__, &1))

  @doc """
  The plans a customer may choose, cheapest first.

  `legacy` is excluded: it is closed to new subscriptions, and showing a
  hidden tier in the picker is how a customer talks themselves onto one.
  """
  @spec public() :: [t()]
  def public, do: Enum.filter(all(), & &1.public?)

  @doc "Every known slug."
  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @doc """
  The slugs a customer may buy — everything `public/0` lists.

  Distinct from `slugs/0` on purpose: this is the vocabulary a *request* may
  name (the checkout endpoint's `plan`), while `slugs/0` is the vocabulary a
  *stored row* may hold, which still includes the closed plan.
  """
  @spec public_slugs() :: [String.t()]
  def public_slugs, do: Enum.map(public(), & &1.slug)

  @doc "Whether `slug` names a plan in the catalog."
  @spec known?(term()) :: boolean()
  def known?(slug) when is_binary(slug), do: slug in @slugs
  def known?(_), do: false

  @doc "The plan for `slug`, or `nil`. Prefer `resolve/1` on a request path."
  @spec get(term()) :: t() | nil
  def get(slug) when is_binary(slug), do: Enum.find(all(), &(&1.slug == slug))
  def get(_), do: nil

  @doc "The plan for `slug`, raising if it is not in the catalog. For tests and mix tasks."
  @spec fetch!(String.t()) :: t()
  def fetch!(slug) when is_binary(slug),
    do: get(slug) || raise(ArgumentError, "unknown plan #{inspect(slug)}")

  @doc """
  This deployment's default plan slug — `config :fountain, :default_plan`,
  from `DEFAULT_PLAN`. Falls back to `solo` if it is unset or names a plan
  that does not exist.
  """
  @spec default_slug() :: String.t()
  def default_slug do
    configured = Application.get_env(:fountain, :default_plan)
    if known?(configured), do: configured, else: @fallback_default
  end

  @doc "This deployment's default plan."
  @spec default() :: t()
  def default, do: fetch!(default_slug())

  @doc """
  The plan for a user, a slug, or `nil` — always a plan, never `nil`.

  A `nil` or unrecognised slug resolves to `default/0`, so a row holding a
  retired plan tightens to a known one rather than raising on every read.
  """
  @spec resolve(term()) :: t()
  def resolve(%__MODULE__{} = plan), do: plan
  def resolve(%{plan: slug}), do: resolve(slug)
  def resolve(slug) when is_binary(slug), do: get(slug) || default()
  def resolve(_), do: default()

  @doc "The concurrent-sandbox cap for a user, slug or plan."
  @spec concurrent_sandboxes(term()) :: non_neg_integer()
  def concurrent_sandboxes(%__MODULE__{concurrent_sandboxes: n}), do: n
  def concurrent_sandboxes(subject), do: resolve(subject).concurrent_sandboxes

  @doc """
  The turn hours a user's, slug's or plan's subscription includes per billing
  period.

  A turn hour is an hour with a prompt in flight, on a provider Fountain pays
  for. It is **not** wall-clock sandbox time: see the moduledoc, and
  `Fountain.Billing.turn_hour_allowance/2` for the used side of the same
  number.

  Reported everywhere, enforced nowhere — no code path refuses anything
  because a tenant is over.
  """
  @spec included_turn_hours(term()) :: non_neg_integer()
  def included_turn_hours(%__MODULE__{included_turn_hours: n}), do: n
  def included_turn_hours(subject), do: resolve(subject).included_turn_hours

  @doc """
  The most teammate contacts a user, slug or plan may hold at once.

  A ceiling on provisioning, not an allowance — the contacts themselves are
  billed per unit. See the moduledoc.
  """
  @spec team_contacts(term()) :: non_neg_integer()
  def team_contacts(%__MODULE__{team_contacts: n}), do: n
  def team_contacts(subject), do: resolve(subject).team_contacts

  @doc "Display price in cents for a user, slug or plan."
  @spec monthly_cents(term()) :: non_neg_integer()
  def monthly_cents(%__MODULE__{monthly_cents: cents}), do: cents
  def monthly_cents(subject), do: resolve(subject).monthly_cents

  @doc """
  Whether moving from `from` to `to` is a move up the ladder.

  `legacy` orders below every public plan, which is what makes it
  upgrade-only: every offer is an upgrade and none is a downgrade back onto a
  closed price.
  """
  @spec upgrade?(term(), term()) :: boolean()
  def upgrade?(from, to), do: resolve(to).order > resolve(from).order

  ## Stripe price ids

  @doc """
  The Stripe price id for a plan, or `nil` when this deployment has none.

  Read from `config :fountain, :stripe_price_ids` (a `%{slug => price_id}`
  map built in `config/runtime.exs` from `STRIPE_PRICE_ID_SOLO`,
  `STRIPE_PRICE_ID_TEAM` and `STRIPE_PRICE_ID_SCALE`), with `legacy` falling
  back to the original single `STRIPE_PRICE_ID`.

  `nil` is not an error: a self-hosted instance has no Stripe at all, and a
  plan with no price simply cannot be subscribed to.
  """
  @spec price_id(term()) :: String.t() | nil
  def price_id(subject) do
    slug = resolve(subject).slug

    case Map.get(price_ids(), slug) do
      id when is_binary(id) and id != "" -> id
      _ -> legacy_fallback(slug)
    end
  end

  @doc """
  The plan slug a Stripe price id belongs to, or `nil` for a price this
  deployment does not know.

  This is what turns a `customer.subscription.updated` webhook into an
  entitlement. An unknown price returning `nil` matters: it must leave the
  stored plan alone rather than silently resolving to the default, because
  the realistic cause is an env var that has not been set yet on one replica.
  """
  @spec slug_for_price_id(term()) :: String.t() | nil
  def slug_for_price_id(price_id) when is_binary(price_id) and price_id != "" do
    Enum.find_value(all(), fn plan ->
      if price_id(plan) == price_id, do: plan.slug
    end)
  end

  def slug_for_price_id(_), do: nil

  @doc """
  The Stripe price id for one teammate contact — the add-on item whose
  quantity is a tenant's contact count. `nil` when unconfigured, which is how
  a deployment runs teammate comms without charging for them.
  """
  @spec contact_price_id() :: String.t() | nil
  def contact_price_id do
    case Map.get(price_ids(), "contact") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc "Display price in cents for one teammate contact per month."
  @spec contact_monthly_cents() :: non_neg_integer()
  def contact_monthly_cents do
    Application.get_env(:fountain, :stripe_contact_price_cents, 500)
  end

  @doc """
  Format cents the way every price surface shows them: `2900` → `"$29"`,
  `2950` → `"$29.50"`.
  """
  @spec format_usd(integer()) :: String.t()
  def format_usd(cents) when is_integer(cents) and rem(cents, 100) == 0,
    do: "$#{div(cents, 100)}"

  def format_usd(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  # Not `get_env(..., %{})`: that default applies only when the key is
  # *absent*, and a key explicitly set to nil is a real state — config that
  # computed to nil, or anything that has written the key back. Reading it as
  # an empty map keeps a half-configured deployment showing no plans instead
  # of raising BadMapError on the marketing page.
  defp price_ids do
    case Application.get_env(:fountain, :stripe_price_ids) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # The tiers arrived after the flat price had been selling for months. Its
  # id is still `STRIPE_PRICE_ID`, and every account that bought it is on
  # `legacy`, so that one env var keeps its old meaning rather than being
  # renamed underneath a running deployment.
  defp legacy_fallback("legacy") do
    case Application.get_env(:fountain, :stripe_price_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp legacy_fallback(_), do: nil
end
