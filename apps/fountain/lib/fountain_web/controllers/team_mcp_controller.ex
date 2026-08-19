defmodule FountainWeb.TeamMcpController do
  @moduledoc """
  The MCP endpoint a teammate's sandbox calls to see and message the rest of
  the team (#851). Streamable-HTTP: one JSON-RPC message per POST. The
  sandbox authenticates with its per-conversation token; the conversation in
  the path must be the caller's and on the team channel, which is what makes
  the tools "the team" and not "any conversation I can name".
  """
  use FountainWeb, :controller

  alias Fountain.{Conversations, Team}
  alias Fountain.Team.Mcp

  def handle(conn, %{"conversation_id" => conv_id}) do
    user = conn.assigns.current_user

    case build_ctx(conn, conv_id, user) do
      {:ok, ctx} ->
        case Mcp.handle(conn.body_params, ctx) do
          :noreply -> send_resp(conn, 202, "")
          resp -> json(conn, resp)
        end

      {:error, status, message} ->
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  defp build_ctx(conn, conv_id, user) do
    case Conversations.get_conversation(conv_id, user.id) do
      %Conversations.Conversation{channel_id: ch} = conv ->
        if ch == Team.channel() do
          self = conv.agent_id && Team.get_teammate(user.id, conv.agent_id)

          {:ok,
           Map.merge(
             %{user_id: user.id, self: self},
             Map.new(FountainWeb.Audited.attribution(conn))
           )}
        else
          {:error, 404, "not a team conversation"}
        end

      nil ->
        {:error, 404, "conversation not found"}
    end
  rescue
    Ecto.Query.CastError -> {:error, 404, "conversation not found"}
  end
end
