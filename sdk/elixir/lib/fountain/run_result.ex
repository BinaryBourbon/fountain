defmodule Fountain.RunResult do
  @moduledoc "The completed result of one agent turn."
  @enforce_keys [:conversation_id, :url, :turn_number, :text, :tools_used, :state]
  defstruct [
    :conversation_id,
    :url,
    :turn_number,
    :text,
    :tools_used,
    :state,
    :exit_code,
    :reason,
    :status,
    :events
  ]
end
