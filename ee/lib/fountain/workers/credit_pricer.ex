defmodule Fountain.Workers.CreditPricer do
  @moduledoc """
  Prices what a tenant used into the credit ledger (ADR 0030 decision 3).

  Two passes, both idempotent, both bounded by `credits.pricing_since`:

    * **Turns.** Every closed turn (`ended_at` set) on a provider Fountain pays
      for burns `Credits.turn_cost_cents(ended - started)` under the key
      `burn_turn:<turn_id>`. A turn is priced once, when it closes: an
      in-flight turn that crosses zero finishes and lands as debt, which is
      the soft stop of decision 6. Runner turns cost Fountain nothing and burn
      nothing (ADR 0022); a turn with no sandbox never ran.
    * **Messages.** Every `comms_email_sent`, `comms_sms_sent` and
      `comms_sms_received` usage event burns the matching price under
      `burn_message:<event_id>`. A `nil` price burns nothing (#1042).

  Rows are written for every tenant, comped included: the ledger is also how
  `Finance` sees what a comp cost. Enforcement is `check_balance/1`'s job and
  is not wired yet (#1086 phase 4).

  No-ops when billing is off or `pricing_since` is unset. The look-back is
  `pricing_since` or seven days, whichever is later, so a restart after an
  outage catches up without scanning the whole table; a turn older than that
  which somehow escaped pricing is a reconciliation job, not this one's.

  Rounding is to the nearest cent per turn. A one-minute turn at $0.25/hour is
  0.4 cents and burns nothing; the error is symmetric and averages out, and a
  ledger of fractional cents is a ledger nobody can reconcile.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3, unique: [period: 60]

  import Ecto.Query

  alias Fountain.Billing
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Turn
  alias Fountain.Credits
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  require Logger

  @lookback_days 7
  @batch 500
  @message_events ~w(comms_email_sent comms_sms_sent comms_sms_received)

  @impl Oban.Worker
  def perform(_job) do
    case run() do
      %{turns: 0, messages: 0} ->
        :ok

      counts ->
        Logger.info("credit pricer: burned #{counts.turns} turns, #{counts.messages} messages")
    end

    :ok
  end

  @doc """
  Run both passes now. `:now` pins the clock; `:since` overrides the
  configured floor. Returns `%{turns: n, messages: n}` — rows written, not
  rows seen.
  """
  @spec run(keyword()) :: %{turns: non_neg_integer(), messages: non_neg_integer()}
  def run(opts \\ []) do
    since = Keyword.get(opts, :since) || pricing_since()

    cond do
      not Billing.enabled?() -> %{turns: 0, messages: 0}
      is_nil(since) -> %{turns: 0, messages: 0}
      true -> do_run(floor(since, Keyword.get(opts, :now) || DateTime.utc_now()))
    end
  end

  @doc "The configured instant burning starts, or nil."
  @spec pricing_since() :: DateTime.t() | nil
  def pricing_since do
    Application.get_env(:fountain, :credits, []) |> Keyword.get(:pricing_since)
  end

  defp floor(since, now) do
    lookback = DateTime.add(now, -@lookback_days * 86_400, :second)
    if DateTime.compare(since, lookback) == :gt, do: since, else: lookback
  end

  defp do_run(floor) do
    %{turns: price_turns(floor), messages: price_messages(floor)}
  end

  # ---------------------------------------------------------------------------
  # Turns
  # ---------------------------------------------------------------------------

  defp price_turns(floor), do: price_turns(floor, 0)

  defp price_turns(floor, written) do
    case unpriced_turns(floor) do
      [] ->
        written

      turns ->
        n = Enum.count(turns, &price_turn/1)
        # The anti-join hides what was just written, so the next page is the
        # next unpriced batch. A page that wrote nothing (every turn was free,
        # or a duplicate) would loop forever; stop on it.
        if n == 0 or length(turns) < @batch,
          do: written + n,
          else: price_turns(floor, written + n)
    end
  end

  defp unpriced_turns(floor) do
    providers = SandboxUsage.platform_paid_providers()

    from(t in Turn,
      join: c in Conversation,
      on: c.id == t.conversation_id,
      join: s in Sandbox,
      on: s.id == c.sandbox_id,
      left_join: l in LedgerEntry,
      on: l.idempotency_key == fragment("'burn_turn:' || ?::text", t.id),
      where: is_nil(l.id),
      where: not is_nil(t.started_at) and not is_nil(t.ended_at),
      where: t.ended_at >= ^floor,
      where: s.provider in ^providers,
      where: not is_nil(c.user_id),
      order_by: [asc: t.ended_at],
      limit: @batch,
      select: %{
        id: t.id,
        user_id: c.user_id,
        conversation_id: c.id,
        provider: s.provider,
        started_at: t.started_at,
        ended_at: t.ended_at
      }
    )
    |> Repo.all()
  end

  # True when a row was written. A turn that rounds to nothing is not written
  # at all, so it will be seen again next run and skipped again; that costs
  # one anti-join row per free turn per run, and the look-back bounds it.
  defp price_turn(turn) do
    seconds = max(DateTime.diff(turn.ended_at, turn.started_at, :second), 0)

    case Credits.turn_cost_cents(seconds) do
      0 ->
        false

      cents ->
        case Credits.debit(turn.user_id, cents, "burn_turn",
               idempotency_key: "burn_turn:#{turn.id}",
               resource_type: "turn",
               resource_id: turn.id,
               actor: "system:credit_pricer",
               metadata: %{
                 "turn_seconds" => seconds,
                 "provider" => turn.provider,
                 "conversation_id" => turn.conversation_id
               }
             ) do
          {:ok, _} ->
            true

          {:ok, :duplicate, _} ->
            false

          {:error, reason} ->
            Logger.warning("credit pricer: turn #{turn.id} not priced: #{inspect(reason)}")
            false
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  defp price_messages(floor) do
    card = Credits.price_card()

    prices = %{
      "comms_email_sent" => card.email_message,
      "comms_sms_sent" => card.sms_message,
      "comms_sms_received" => card.sms_message
    }

    priced_types = for {type, cents} <- prices, is_integer(cents) and cents > 0, do: type

    if priced_types == [] do
      0
    else
      floor
      |> unpriced_messages(priced_types)
      |> Enum.count(&price_message(&1, Map.fetch!(prices, &1.event_type)))
    end
  end

  defp unpriced_messages(floor, types) do
    from(e in UsageEvent,
      left_join: l in LedgerEntry,
      on: l.idempotency_key == fragment("'burn_message:' || ?::text", e.id),
      where: is_nil(l.id),
      where: e.event_type in ^types and e.event_type in ^@message_events,
      where: e.inserted_at >= ^floor,
      order_by: [asc: e.inserted_at],
      limit: @batch,
      select: %{
        id: e.id,
        user_id: e.user_id,
        event_type: e.event_type,
        resource_id: e.resource_id
      }
    )
    |> Repo.all()
  end

  defp price_message(event, cents) do
    case Credits.debit(event.user_id, cents, "burn_message",
           idempotency_key: "burn_message:#{event.id}",
           resource_type: "usage_event",
           resource_id: Integer.to_string(event.id),
           actor: "system:credit_pricer",
           metadata: %{"event_type" => event.event_type, "contact_id" => event.resource_id}
         ) do
      {:ok, _} ->
        true

      {:ok, :duplicate, _} ->
        false

      {:error, reason} ->
        Logger.warning("credit pricer: message #{event.id} not priced: #{inspect(reason)}")
        false
    end
  end
end
