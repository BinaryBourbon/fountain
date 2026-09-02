defmodule Fountain.Client do
  @moduledoc """
  The configured Fountain API client.

  Its small resolver cache is owned by the process that calls `Fountain.new/1`; use the client
  from that process or while it remains alive.
  """
  defstruct [:config, :api, :resolver, :agents, :environments, :vaults, :team, :connections]
end
