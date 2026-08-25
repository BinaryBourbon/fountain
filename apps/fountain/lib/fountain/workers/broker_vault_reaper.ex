defmodule Fountain.Workers.BrokerVaultReaper do
  @moduledoc """
  Deletes a conversation's vault on the egress broker once its request log
  has outlived `BROKER_LOG_RETENTION_HOURS` (ADR 0019 gate 4).

  `Fountain.Broker.release/1` strips a vault at the end of a conversation but
  keeps it, because the request log in it is the effect half of the audit
  trail. Left alone, one vault per conversation would accumulate forever;
  this pass, daily, deletes the ones whose conversation ended long enough
  ago, and any vault of ours whose conversation no longer exists at all.

  A no-op when the broker is not configured.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Fountain.Broker
  alias Fountain.Conversations.Conversation
  alias Fountain.Repo

  require Logger

  @ended ~w(terminated failed)

  @impl Oban.Worker
  def perform(_job) do
    %{deleted: deleted, failed: failed} = run()

    if deleted > 0 or failed > 0 do
      Logger.info("broker vault reaper: deleted #{deleted} vault(s), #{failed} failed")
    end

    :ok
  end

  @doc "Reap now. `now:` pins the clock; `vaults:` skips the broker's vault listing (tests)."
  @spec run(keyword()) :: %{
          deleted: non_neg_integer(),
          failed: non_neg_integer(),
          kept: non_neg_integer()
        }
  def run(opts \\ []) do
    if Broker.configured?() do
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      cutoff = DateTime.add(now, -Broker.log_retention_hours() * 3600, :second)

      case Keyword.get(opts, :vaults) || vaults() do
        {:error, reason} ->
          Logger.warning("broker vault reaper: could not list vaults: #{inspect(reason)}")
          %{deleted: 0, failed: 0, kept: 0}

        names ->
          names |> Enum.filter(&Broker.conversation_id_for_vault/1) |> reap(cutoff)
      end
    else
      %{deleted: 0, failed: 0, kept: 0}
    end
  end

  defp vaults do
    case Broker.list_vaults() do
      {:ok, names} -> names
      {:error, _} = err -> err
    end
  end

  defp reap(names, cutoff) do
    by_conv = Map.new(names, &{Broker.conversation_id_for_vault(&1), &1})
    ids = Map.keys(by_conv)

    live =
      Repo.all(
        from c in Conversation,
          where: c.id in ^ids,
          select: {c.id, c.status, c.updated_at}
      )
      |> Map.new(fn {id, status, at} -> {id, {status, at}} end)

    Enum.reduce(by_conv, %{deleted: 0, failed: 0, kept: 0}, fn {conv_id, vault}, acc ->
      case Map.get(live, conv_id) do
        nil ->
          delete(vault, acc)

        {status, at} when status in @ended ->
          if(DateTime.before?(at, cutoff), do: delete(vault, acc), else: keep(acc))

        _ ->
          keep(acc)
      end
    end)
  end

  defp keep(acc), do: %{acc | kept: acc.kept + 1}

  defp delete(vault, acc) do
    case Broker.delete_vault(vault) do
      :ok ->
        %{acc | deleted: acc.deleted + 1}

      {:error, reason} ->
        Logger.warning("broker vault reaper: #{vault}: #{inspect(reason)}")
        %{acc | failed: acc.failed + 1}
    end
  end
end
