defmodule Fountain.Workers.CreditExpirer do
  @moduledoc """
  Takes the unused free money back out (ADR 0030 decision 2, ADR 0031): a
  grant whose `expires_at` has passed loses what its lot still holds, under
  `expire:<grant_id>`. Daily, and on every tick of `Workers.CreditPricer`, so
  an expired grant is swept within minutes rather than at the next 06:23. The
  opening grant is posted at verification (`Credits.grant_opening/2`); an
  operator's grant never expires.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3, unique: [period: 60]

  import Ecto.Query

  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  require Logger

  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    case run() do
      %{expired: 0} -> :ok
      c -> Logger.info("credit expirer: #{c.expired} expiries")
    end

    :ok
  end

  @doc "Run the expiry pass now. `:now` pins the clock. Counts rows written."
  @spec run(keyword()) :: %{expired: non_neg_integer()}
  def run(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    if Billing.enabled?(), do: %{expired: expire_grants(now)}, else: %{expired: 0}
  end

  # ---------------------------------------------------------------------------
  # Expiry
  # ---------------------------------------------------------------------------

  defp expire_grants(now) do
    from(g in LedgerEntry,
      where: g.amount_cents > 0 and not is_nil(g.expires_at) and g.expires_at <= ^now,
      left_join: x in LedgerEntry,
      on: x.idempotency_key == fragment("'expire:' || ?::text", g.id),
      where: is_nil(x.id),
      order_by: [asc: g.expires_at],
      limit: @batch
    )
    |> Repo.all()
    |> Enum.count(&expire_grant/1)
  end

  # A fully-spent grant writes nothing (a zero row is invalid) and so is
  # re-examined every run; the anti-join keeps that to one cheap row per
  # spent grant per run. The amount is read inside the ledger's transaction
  # (`Credits.expire_lot/2`), so a burn racing this sweep cannot make the
  # expiry take more than the grant still had.
  defp expire_grant(%LedgerEntry{} = grant) do
    case Credits.expire_lot(grant, actor: "system:credit_expirer") do
      {:ok, :nothing} ->
        false

      {:ok, _} ->
        true

      {:ok, :duplicate, _} ->
        false

      {:error, why} ->
        Logger.warning("credit expirer: expire #{grant.id} failed: #{inspect(why)}")
        false
    end
  end
end
