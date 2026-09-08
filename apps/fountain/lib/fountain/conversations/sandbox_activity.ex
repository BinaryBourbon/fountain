defmodule Fountain.Conversations.SandboxActivity do
  @moduledoc """
  Durable activity across a machine's current holders.

  Read under the machine and parent locks when authorizing a transition.
  Reads outside those locks are sweep hints only. Bookkeeping timestamps do
  not count; attachment, wake, turn start and turn end do. Historical holders
  retain their recent activity until moved to another machine.
  """
  import Ecto.Query
  alias Fountain.Repo
  alias Fountain.Conversations.{Lifecycle, Turn}

  def _unsafe_check(sandbox, parents, now) do
    ids = Enum.map(parents, & &1.id)

    {inserted, started, ended, running} =
      Repo.one(
        from t in Turn,
          where: t.conversation_id in ^ids,
          select:
            {max(t.inserted_at), max(t.started_at), max(t.ended_at),
             filter(count(t.id), t.status == "running")}
      )

    clock = sandbox.last_resumed_at || sandbox.inserted_at

    activity =
      [
        clock,
        sandbox.last_attached_at,
        inserted,
        started,
        ended | Enum.map(parents, & &1.inserted_at)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime)

    Lifecycle.check(clock, activity, running > 0, now)
  end
end
