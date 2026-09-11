defmodule Fountain.Workers.SandboxResetReconciler do
  @moduledoc """
  Retry fenced sandbox deletions without releasing capacity on an uncertain result.

  The scheduled sweep discovers fences left by errors or lost callers. Each
  sandbox gets one durable job; Oban backs off failed deletes independently.
  A discarded job becomes eligible on a later sweep, so an extended provider
  outage never makes a fence permanent. Disabled providers wait for credentials.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sandbox_id" => id}}) do
    case Repo.get(Sandbox, id) do
      %Sandbox{mode: "persistent", status: status, reset_requested_at: at} = sandbox
      when status in ["ready", "suspended"] and not is_nil(at) ->
        if Fountain.SandboxProviders.enabled?(Conversations.sandbox_provider_atom(sandbox)) do
          case Conversations.retry_pending_sandbox_reset(sandbox,
                 actor: "system:sandbox_reset_reconciler"
               ) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          {:snooze, 300}
        end

      _ ->
        :ok
    end
  end

  def perform(%Oban.Job{args: %{}}) do
    from(s in Sandbox,
      where:
        s.mode == "persistent" and s.status in ["ready", "suspended"] and
          not is_nil(s.reset_requested_at),
      select: s.id
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case %{sandbox_id: id} |> new() |> Oban.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
