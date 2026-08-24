defmodule Fountain.Billing.Reconciliation do
  @moduledoc """
  Computed spend held next to what the provider actually charged (#1038
  step 1), and the count of metering events this node has dropped (step 2).

  `Finance.summary/1` is a plausible number with an unknown error until a
  real invoice sits beside it. `record_invoice/2` stores one per provider
  per month; `lines/2` produces, for every provider Fountain pays, the
  computed cents, the recorded cents, and the delta. A month of deltas is
  what turns each gap in the model from a silent bias into a measured one,
  and is what gates enforcement (ADR 0030 §8).

  Recording an invoice is an admin act on platform data, not on a tenant, so
  the audit row carries no `user_id` and an `admin:<id>` actor.
  """

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Billing.ProviderInvoice
  alias Fountain.Repo

  @doc """
  Record (or replace) what `provider` charged for the month starting
  `period_start`. `attrs` is string-keyed: `provider`, `period_start`,
  `period_end`, `amount_cents`, `note`. Options carry the audit attribution.
  """
  @spec record_invoice(map(), keyword()) ::
          {:ok, ProviderInvoice.t()} | {:error, Ecto.Changeset.t()}
  def record_invoice(attrs, opts \\ []) do
    changeset = ProviderInvoice.changeset(%ProviderInvoice{}, attrs)

    with {:ok, invoice} <-
           Repo.insert(changeset,
             on_conflict: {:replace, [:period_end, :amount_cents, :note, :updated_at]},
             conflict_target: [:provider, :period_start],
             returning: true
           ) do
      Audit.record(%{
        user_id: nil,
        action: "finance.invoice.recorded",
        resource_type: "provider_invoice",
        resource_id: invoice.id,
        actor: Keyword.get(opts, :actor, "admin"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "provider" => invoice.provider,
          "period_start" => Date.to_iso8601(invoice.period_start),
          "amount_cents" => invoice.amount_cents
        }
      })

      {:ok, invoice}
    end
  end

  @doc "Invoices recorded for the month starting `period_start`, by provider."
  @spec invoices_for(Date.t()) :: %{optional(String.t()) => ProviderInvoice.t()}
  def invoices_for(%Date{} = period_start) do
    from(i in ProviderInvoice, where: i.period_start == ^period_start)
    |> Repo.all()
    |> Map.new(&{&1.provider, &1})
  end

  @typedoc "One provider's computed-versus-invoiced line."
  @type line :: %{
          provider: String.t(),
          computed_cents: integer() | nil,
          recorded_cents: integer() | nil,
          delta_cents: integer() | nil,
          note: String.t() | nil
        }

  @doc """
  One line per provider Fountain pays, from a `Finance.summary/1` and the
  invoices recorded for its month. `computed_cents` is nil where the rate
  card cannot price the provider; `delta_cents` is recorded minus computed,
  so a positive delta means the model under-reports.
  """
  @spec lines(map(), %{optional(String.t()) => ProviderInvoice.t()}) :: [line()]
  def lines(summary, invoices) do
    computed = computed_by_provider(summary)

    for provider <- ProviderInvoice.providers() do
      c = Map.get(computed, provider)
      r = invoices[provider] && invoices[provider].amount_cents

      %{
        provider: provider,
        computed_cents: c,
        recorded_cents: r,
        delta_cents: if(is_integer(c) and is_integer(r), do: r - c),
        note: invoices[provider] && invoices[provider].note
      }
    end
  end

  # Sandbox providers from the attribution roll-up at the summary's basis;
  # AgentMail is inboxes plus email, AgentPhone numbers plus SMS, pro-rated
  # and rounded the way `Finance` does it so the two never disagree.
  defp computed_by_provider(summary) do
    card = summary.rate_card
    cost = summary.cost
    fraction = summary.period_fraction

    sandboxes =
      Map.new(cost.by_provider, fn {provider, totals} ->
        seconds = if(card.basis == :turn, do: totals.busy_seconds, else: totals.active_seconds)

        cents =
          case Map.get(card.providers, provider) do
            nil -> nil
            rate -> round(seconds / 3600 * rate)
          end

        {provider, cents}
      end)

    agentmail =
      add([
        monthly(cost.inboxes, card.inbox_month, fraction),
        per_message(cost.emails_sent, card.email)
      ])

    agentphone =
      add([
        monthly(cost.numbers, card.number_month, fraction),
        per_message(cost.sms_sent + cost.sms_received, card.sms)
      ])

    sandboxes |> Map.put("agentmail", agentmail) |> Map.put("agentphone", agentphone)
  end

  defp monthly(0, _cents, _fraction), do: 0
  defp monthly(_units, nil, _fraction), do: nil
  defp monthly(units, cents, fraction), do: units * cents * fraction

  defp per_message(0, _cents), do: 0
  defp per_message(_n, nil), do: nil
  defp per_message(n, cents), do: n * cents

  defp add(parts) do
    if Enum.any?(parts, &is_nil/1), do: nil, else: parts |> Enum.sum() |> round()
  end

  @doc """
  Metering events dropped on this node since it booted (`[:fountain, :usage,
  :dropped]`). A non-zero count means the period's figures rest on an
  incomplete record. Per node and since boot — a fleet-wide, durable count is
  what a metric backend is for; this is the number that belongs beside the
  figures it undermines.
  """
  @spec dropped_on_this_node() :: non_neg_integer()
  def dropped_on_this_node do
    case :persistent_term.get({__MODULE__, :dropped}, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @doc false
  def attach_drop_counter do
    ref = :counters.new(1, [:write_concurrency])
    :persistent_term.put({__MODULE__, :dropped}, ref)

    :telemetry.attach(
      "fountain-usage-dropped-counter",
      [:fountain, :usage, :dropped],
      &__MODULE__.handle_drop/4,
      ref
    )
  end

  @doc false
  def handle_drop(_event, %{count: n}, _meta, ref), do: :counters.add(ref, 1, n)

  @doc false
  def reset_drop_counter do
    case :persistent_term.get({__MODULE__, :dropped}, nil) do
      nil -> :ok
      ref -> :counters.put(ref, 1, 0)
    end
  end
end
