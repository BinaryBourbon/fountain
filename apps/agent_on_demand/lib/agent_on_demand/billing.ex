defmodule AgentOnDemand.Billing do
  @moduledoc """
  Records usage events for billing and observability.

  Each event is written synchronously (blocking the caller until the row
  is durable) so that billing records are never silently dropped even if
  the process crashes immediately afterward.

  The `usage_events` table is provisioned by the phase-3-foundation
  migration. Schema:

    id            uuid        PK
    user_id       uuid        FK → users (not null)
    event_type    text        one of: sandbox_provisioned, turn_started, sandbox_terminated
    resource_id   uuid        the sandbox or turn id (nullable)
    resource_type text        "sandbox" | "turn"
    metadata      jsonb       arbitrary extra context
    inserted_at   timestamptz
  """

  alias AgentOnDemand.Repo

  @valid_event_types ~w(sandbox_provisioned turn_started sandbox_terminated)

  @doc """
  Emit a billing event synchronously.

  ## Parameters
  - `user_id`       — tenant who owns the resource
  - `event_type`    — one of `sandbox_provisioned`, `turn_started`, `sandbox_terminated`
  - `resource_id`   — UUID of the sandbox or turn (may be nil for edge cases)
  - `resource_type` — `"sandbox"` or `"turn"`
  - `metadata`      — additional context (default `%{}`)
  """
  @spec emit(binary(), binary(), binary() | nil, binary(), map()) :: :ok
  def emit(user_id, event_type, resource_id, resource_type, metadata \\ %{})
      when event_type in @valid_event_types do
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all("usage_events", [
        %{
          id: Ecto.UUID.generate(),
          user_id: user_id,
          event_type: event_type,
          resource_id: resource_id,
          resource_type: resource_type,
          metadata: metadata,
          inserted_at: now
        }
      ])

    :ok
  end
end
