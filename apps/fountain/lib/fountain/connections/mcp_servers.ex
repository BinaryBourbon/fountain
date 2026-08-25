defmodule Fountain.Connections.McpServers do
  @moduledoc """
  How a connection is named in an agent's `mcp_servers`, and how that entry
  becomes the server the sandbox actually talks to (#1178).

  An agent names a connection instead of a token:

      %{"gmail" => %{"connection" => "<connection id>"}}

  At spawn, `resolve/3` rewrites that entry into an HTTP MCP server pointing
  at `POST /api/mcp/gmail/:conversation_id/:connection_id`, authenticated by
  the conversation's own callback token, which the sandbox already holds. It
  is the same shape a tenant would write for any remote MCP server, so it
  flows through `.mcp.json` (claude) and `session/new` (everyone else)
  without a new contract. The connection id is validated at request time
  by `FountainWeb.GmailMcpController`; a stale or revoked one fails there
  with a reason the model can read.
  """

  @doc "True for an `mcp_servers` entry that names a connection."
  def connection_entry?(%{"connection" => id}) when is_binary(id), do: true
  def connection_entry?(_), do: false

  @doc "The connection ids an agent's `mcp_servers` names."
  def connection_ids(nil), do: []

  def connection_ids(mcp_servers) when is_map(mcp_servers) do
    for {_name, %{"connection" => id}} <- mcp_servers, is_binary(id), uniq: true, do: id
  end

  @doc """
  Rewrite every connection entry into the HTTP server the sandbox calls.
  With no callback token yet (`nil`), connection entries are dropped rather
  than shipped half-built — the turn kick recomputes with the token.
  """
  def resolve(mcp_servers, conversation_id, token)

  def resolve(mcp_servers, _conversation_id, _token)
      when not is_map(mcp_servers) or map_size(mcp_servers) == 0,
      do: mcp_servers

  def resolve(mcp_servers, conversation_id, token) when is_map(mcp_servers) do
    Enum.reduce(mcp_servers, %{}, fn
      {name, %{"connection" => id}}, acc when is_binary(id) ->
        if is_binary(token) and is_binary(conversation_id),
          do: Map.put(acc, name, server(conversation_id, id, token)),
          else: acc

      {name, entry}, acc ->
        Map.put(acc, name, entry)
    end)
  end

  defp server(conversation_id, connection_id, token) do
    %{
      "type" => "http",
      "url" => Fountain.PublicUrl.base() <> "/api/mcp/gmail/#{conversation_id}/#{connection_id}",
      "headers" => %{"Authorization" => "Bearer " <> token}
    }
  end
end
