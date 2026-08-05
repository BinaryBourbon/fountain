defmodule FountainWeb.AuditJSON do
  @moduledoc false

  alias Fountain.Audit.Event

  def index(%{events: events, has_more: has_more?, limit: limit}) do
    %{
      data: Enum.map(events, &data/1),
      meta: %{
        limit: limit,
        has_more: has_more?,
        # Pass back as `before`. nil on an empty page: there is nothing to
        # resume from, and echoing the request's cursor invites a loop.
        next_cursor: events |> List.last() |> event_id()
      }
    }
  end

  defp data(%Event{} = e) do
    %{
      id: e.id,
      inserted_at: e.inserted_at,
      actor: e.actor,
      action: e.action,
      resource_type: e.resource_type,
      resource_id: e.resource_id,
      metadata: e.metadata,
      request_ip: e.request_ip
    }
  end

  defp event_id(%Event{id: id}), do: id
  defp event_id(nil), do: nil
end
