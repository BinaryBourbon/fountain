defmodule FountainWeb.SearchJSON do
  @moduledoc false

  def index(%{result: %{hits: hits, has_more: has_more, limit: limit, offset: offset}}) do
    %{
      data: Enum.map(hits, &hit/1),
      meta: %{limit: limit, offset: offset, has_more: has_more}
    }
  end

  defp hit(h) do
    %{
      kind: h.kind,
      conversation_id: h.conversation_id,
      agent_id: h.agent_id,
      turn_id: h.turn_id,
      turn_number: h.turn_number,
      snippet: h.snippet,
      ts: h.ts
    }
  end
end
