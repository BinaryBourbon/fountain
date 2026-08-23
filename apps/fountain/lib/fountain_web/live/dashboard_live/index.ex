defmodule FountainWeb.DashboardLive.Index do
  @moduledoc """
  The console's home, and what greets a new account (#867).

  It replaced the onboarding wizard, which was four pages an account could
  not leave until it finished. The same three things have to be true before
  an agent can run — an inference credential, an agent, and somewhere to
  watch it — so they are listed here, ticked as they are done, and the
  account is free to do them in any order or not at all.
  """
  use FountainWeb, :live_view

  alias Fountain.{
    Accounts,
    Agents,
    Apps,
    Conversations,
    Environments,
    InferenceCredentials,
    Vaults
  }

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    agents = Agents.list_agents(user.id, [])
    counts = Conversations.conversation_counts(user.id)
    has_credential? = InferenceCredentials.has_any_credential?(user.id)

    # `onboarding_completed_at` used to be stamped by the wizard's last step.
    # Nothing else ever set it, so with the wizard gone the lifecycle funnel's
    # "onboarded" stage would have flatlined (Fountain.Funnel). Stamp it here
    # instead, off what the checklist actually asks for — a truer definition
    # than "clicked through four pages", and idempotent.
    maybe_complete_onboarding(user, has_credential?, agents)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:agent_count, length(agents))
     |> assign(:environment_count, length(Environments.list_environments(user.id)))
     |> assign(:vault_count, length(Vaults.list_vaults(user.id)))
     |> assign(:has_credential?, has_credential?)
     |> assign(:active_count, counts.active)
     |> assign(:conversation_count, counts.total)
     |> assign(:recent_conversations, Conversations.list_conversations(user.id, limit: 5))
     |> assign(:conversations_app, Apps.conversations())
     |> assign(:team_app, Apps.team())
     |> assign_usage(user)}
  end

  # The window Stripe invoices where there is one, the calendar month
  # otherwise — the same call the billing page makes, so the two pages cannot
  # report different numbers for "this period". `period.source` says which it
  # got, and the heading says so too: a customer whose invoice runs the 20th
  # to the 20th was being shown a calendar month here and an invoiced period
  # one click away.
  #
  # The counts come from usage events, which are written whether or not
  # billing is switched on, so a self-hosted console still sees what its
  # agents have been doing.
  defp assign_usage(socket, user) do
    billing_enabled? = Fountain.Billing.enabled?()
    period = Fountain.Billing.billing_period(user)

    socket
    |> assign(:usage, Fountain.Billing.usage_summary(user.id, period.start, period.end))
    |> assign(:tokens, Conversations.token_usage(user.id, period.start, period.end))
    |> assign(:period, period)
    |> assign(:period_start, period.start)
    |> assign(:billing_enabled?, billing_enabled?)
    # Two queries against the sandbox and turn rows, so it is skipped where
    # there is no allowance to report at all.
    |> assign(
      :allowance,
      billing_enabled? && Fountain.Billing.turn_hour_allowance(user, period: period)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Dashboard</h1>
        <a :if={@conversations_app} href={@conversations_app <> "#/new"}>
          <.btn>Start a conversation ↗</.btn>
        </a>
      </div>

      <%!-- Setup, when something is still missing. Ticks disappear once
            everything is in place rather than nagging forever. --%>
      <section :if={not ready?(assigns)} class="rounded-lg border border-[var(--color-border)] p-5">
        <h2 class="text-sm font-semibold">Before an agent can run</h2>
        <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
          Three things, in any order.
        </p>
        <ul class="mt-4 space-y-3">
          <.setup_step
            done={@has_credential?}
            label="An inference credential"
            hint="Your own Anthropic, OpenAI or Google key — Fountain never bills you for tokens."
            href={~p"/account/inference-credentials"}
            cta="Add a key"
          />
          <.setup_step
            done={@agent_count > 0}
            label="An agent"
            hint="A name, a runtime and a model — the thing that runs."
            href={~p"/agents/new"}
            cta="Create an agent"
          />
          <.setup_step
            :if={@conversations_app}
            done={@conversation_count > 0}
            label="A conversation"
            hint="Runs in an isolated sandbox and streams back live, in the conversations app."
            href={@conversations_app <> "#/new"}
            cta="Start one"
            external
          />
        </ul>
      </section>

      <%!-- The apps. External on purpose: their own origins, their own
            tokens, and a deployment may have neither. --%>
      <section :if={@conversations_app || @team_app}>
        <h2 class="text-lg font-medium mb-3">Apps</h2>
        <div class="grid gap-4 sm:grid-cols-2">
          <.app_card
            :if={@conversations_app}
            href={@conversations_app}
            title="Conversations"
            body="Start a run, watch it turn by turn, steer it, read the raw log."
          />
          <.app_card
            :if={@team_app}
            href={@team_app}
            title="Team"
            body="Your agents as teammates — one thread each, schedules, and their activity."
          />
        </div>
      </section>

      <section>
        <div class="flex items-baseline justify-between mb-3">
          <h2 class="text-lg font-medium">
            {if @period.source == :subscription, do: "This billing period", else: "This month"}
          </h2>
          <span class="text-xs text-[var(--color-text-muted)]">
            since {Calendar.strftime(@period_start, "%-d %B")}
            <a
              :if={@billing_enabled?}
              href={~p"/account/billing"}
              class="ml-2 text-[var(--color-brand)] hover:underline"
            >
              Billing
            </a>
          </span>
        </div>
        <div class="grid gap-4 grid-cols-2 lg:grid-cols-4">
          <.metric label="Conversations" value={format_count(@usage.conversations)} />
          <.metric label="Turns" value={format_count(@usage.turns)} />
          <%!-- Turn hours, not sandbox time. Sandbox wall-clock is Fountain's
                cost and nothing a customer buys or is measured on: it went up
                while they slept, and the number that decides whether they are
                inside their plan is this one (Fountain.Plans). The sandbox
                figure stays in the hint, where it explains itself. --%>
          <.metric
            label="Turn hours"
            value={turn_hours_value(assigns)}
            sub={turn_hours_sub(assigns)}
            hint={turn_hours_hint(assigns)}
          />
          <.metric
            label="Tokens"
            value={format_tokens(@tokens)}
            sub={token_sub(@tokens)}
            hint={token_hint(@tokens)}
          />
        </div>
        <%!-- Only when every tile is empty. Usage events are best-effort
              (`Billing.record_usage/5` swallows its failures), so an instance
              can have turns and tokens with no events behind them — and
              "nothing yet" above four populated tiles reads as a bug. --%>
        <p :if={nothing_this_month?(assigns)} class="mt-2 text-xs text-[var(--color-text-muted)]">
          Nothing yet this month.
        </p>
      </section>

      <section>
        <h2 class="text-lg font-medium mb-3">What you have</h2>
        <div class="grid gap-4 grid-cols-2 lg:grid-cols-4">
          <.stat_card label="Agents" value={@agent_count} href={~p"/agents"} />
          <.stat_card label="Environments" value={@environment_count} href={~p"/environments"} />
          <.stat_card label="Vaults" value={@vault_count} href={~p"/vaults"} />
          <.stat_card label="Running now" value={@active_count} href={@conversations_app} external />
        </div>
      </section>

      <section :if={@recent_conversations != []}>
        <h2 class="text-lg font-medium mb-3">Recent conversations</h2>
        <div class="overflow-hidden rounded-lg border border-[var(--color-border)]">
          <table class="w-full text-sm">
            <tbody>
              <tr
                :for={c <- @recent_conversations}
                class="border-b border-[var(--color-border)] last:border-0"
              >
                <td class="px-4 py-2">
                  <.conv_link conversation={c} app={@conversations_app} />
                </td>
                <td class="px-4 py-2"><.badge status={c.status} /></td>
                <td class="px-4 py-2 text-[var(--color-text-muted)] text-xs">
                  {relative_time(c.updated_at)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="mt-2 text-xs text-[var(--color-text-muted)]">
          Transcripts live in the conversations app; this console keeps the account and the
          primitives a conversation runs on.
        </p>
      </section>
    </div>
    """
  end

  defp maybe_complete_onboarding(%{onboarding_completed_at: nil} = user, true, [_ | _]) do
    Accounts.complete_onboarding(user)
  end

  defp maybe_complete_onboarding(_user, _has_credential?, _agents), do: :ok

  defp nothing_this_month?(assigns) do
    assigns.usage.conversations == 0 and assigns.usage.turns == 0 and
      assigns.usage.sandbox_minutes == 0 and Conversations.total_input(assigns.tokens) == 0 and
      assigns.tokens.output == 0
  end

  # Turn hours: the used side always, the allowance beside it when billing is
  # on. Rounded to one place, which is the resolution a customer can act on.
  defp turn_hours_value(%{allowance: %{used: used}}), do: format_hours(used)
  defp turn_hours_value(%{usage: usage}), do: format_hours(billable_turn_hours(usage))

  defp turn_hours_sub(%{allowance: %{included: included}}), do: "of #{included} included"
  defp turn_hours_sub(_assigns), do: nil

  defp turn_hours_hint(assigns) do
    base =
      "Time with a prompt in flight. An agent left running with nobody talking to it " <>
        "spends none of this."

    case assigns.usage.sandbox_minutes do
      minutes when minutes > 0 ->
        base <> " Your sandboxes were awake for #{format_minutes(minutes)}."

      _ ->
        base
    end
  end

  # Billing off: there is no allowance, so the tile falls back to the same
  # arithmetic `Billing.turn_hours_used/2` does — turn time on the providers
  # the platform pays for, which excludes a tenant's own runner (ADR 0022).
  defp billable_turn_hours(usage) do
    Map.get(usage, :turn_hours, 0.0)
  end

  defp format_hours(hours) when is_number(hours) do
    cond do
      hours == 0 -> "0"
      hours < 0.1 -> "<0.1"
      true -> "#{Float.round(hours * 1.0, 1)}"
    end
  end

  defp format_hours(_), do: "—"

  defp ready?(assigns) do
    assigns.has_credential? and assigns.agent_count > 0 and
      (is_nil(assigns.conversations_app) or assigns.conversation_count > 0)
  end

  attr :done, :boolean, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true
  attr :href, :string, required: true
  attr :cta, :string, required: true
  attr :external, :boolean, default: false

  defp setup_step(assigns) do
    ~H"""
    <li class="flex items-start gap-3">
      <span class={[
        "mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border text-xs",
        if(@done,
          do: "border-green-500 bg-green-500/15 text-green-600",
          else: "border-[var(--color-border)] text-[var(--color-text-muted)]"
        )
      ]}>
        {if @done, do: "✓", else: "•"}
      </span>
      <div class="min-w-0 flex-1">
        <p class={[
          "text-sm font-medium",
          @done && "text-[var(--color-text-muted)] line-through"
        ]}>
          {@label}
        </p>
        <p :if={not @done} class="text-xs text-[var(--color-text-secondary)]">{@hint}</p>
      </div>
      <a
        :if={not @done and @external}
        href={@href}
        class="shrink-0 text-sm text-[var(--color-brand)] hover:underline"
      >
        {@cta} ↗
      </a>
      <.link
        :if={not @done and not @external}
        navigate={@href}
        class="shrink-0 text-sm text-[var(--color-brand)] hover:underline"
      >
        {@cta}
      </.link>
    </li>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :hint, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div class="rounded-lg border border-[var(--color-border)] p-4" title={@hint}>
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label}</p>
      <p class="mt-1 text-2xl font-semibold tabular-nums">{@value}</p>
      <p :if={@sub} class="text-[11px] text-[var(--color-text-muted)]">{@sub}</p>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  defp app_card(assigns) do
    ~H"""
    <a
      href={@href}
      class="block rounded-lg border border-[var(--color-border)] p-4 hover:bg-[var(--color-bg-2)] transition-colors"
    >
      <p class="font-medium">{@title} ↗</p>
      <p class="mt-1 text-sm text-[var(--color-text-secondary)]">{@body}</p>
    </a>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :href, :string, default: nil
  attr :external, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <div :if={is_nil(@href)} class="rounded-lg border border-[var(--color-border)] p-4">
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label}</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </div>
    <a
      :if={@href && @external}
      href={@href}
      class="block rounded-lg border border-[var(--color-border)] p-4 hover:bg-[var(--color-bg-2)] transition-colors"
    >
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label} ↗</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </a>
    <.link
      :if={@href && not @external}
      navigate={@href}
      class="block rounded-lg border border-[var(--color-border)] p-4 hover:bg-[var(--color-bg-2)] transition-colors"
    >
      <p class="text-xs uppercase tracking-wide text-[var(--color-text-muted)]">{@label}</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </.link>
    """
  end

  attr :conversation, :map, required: true
  attr :app, :string, default: nil

  defp conv_link(assigns) do
    assigns = assign(assigns, :name, agent_name(assigns.conversation))

    ~H"""
    <a
      :if={@app}
      href={Fountain.Apps.conversation_url(@conversation.id)}
      class="font-medium hover:underline"
    >
      {@name} ↗
    </a>
    <span :if={is_nil(@app)} class="font-medium">{@name}</span>
    """
  end

  # Thousands separators, because six figures of tokens is unreadable without.
  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_count(n), do: to_string(n)

  # Minutes until they stop being readable as minutes.
  defp format_minutes(minutes) when is_number(minutes) do
    cond do
      minutes < 1 -> "<1m"
      minutes < 60 -> "#{round(minutes)}m"
      minutes < 60 * 24 -> "#{Float.round(minutes / 60, 1)}h"
      true -> "#{Float.round(minutes / 60 / 24, 1)}d"
    end
  end

  defp format_minutes(_), do: "—"

  # Two numbers in one tile: what went in, what came back. "In" is every
  # token the model read — a coding agent re-reads its context every turn, so
  # nearly all of it arrives as cached reads, and `input` alone reads as
  # nothing at all.
  defp format_tokens(tokens) do
    case {Conversations.total_input(tokens), tokens.output} do
      {0, 0} -> "—"
      {input, output} -> "#{compact(input)} / #{compact(output)}"
    end
  end

  defp token_sub(tokens) do
    if Conversations.total_input(tokens) > 0 or tokens.output > 0, do: "in / out"
  end

  # The breakdown belongs somewhere, and a tile is not it — but a reader who
  # wonders why "in" is so large deserves the answer on hover.
  defp token_hint(tokens) do
    cached = tokens.cache_read + tokens.cache_write

    base =
      "On your own inference key — Fountain never bills for these."

    if cached > 0 do
      base <>
        " In includes #{format_count(cached)} read from or written to the prompt cache," <>
        " and #{format_count(tokens.input)} fresh."
    else
      base
    end
  end

  defp compact(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp compact(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp compact(n), do: Integer.to_string(n)

  defp agent_name(%{agent: %{name: name}}), do: name
  defp agent_name(_), do: "(no agent)"

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt))

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
