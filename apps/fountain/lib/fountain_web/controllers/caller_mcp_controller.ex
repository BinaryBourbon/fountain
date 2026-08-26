defmodule FountainWeb.CallerMcpController do
  @moduledoc """
  The MCP endpoint a sandbox calls to see and use the tools its *caller*
  defined (#1202, `Fountain.CallerTools`). Streamable-HTTP: one JSON-RPC
  message per POST. The sandbox authenticates with its per-conversation
  token; the conversation in the path must be the caller's and must have
  caller tools registered, which is what makes the tools "what the client
  sent on this thread" and not "any conversation I can name".

  `tools/call` parks the call on the conversation's server and blocks for
  the in-request wait, so the request process is the waiter.
  """
  use FountainWeb, :controller

  alias Fountain.CallerTools.Mcp
  alias Fountain.Conversations

  def handle(conn, %{"conversation_id" => conv_id}) do
    user = conn.assigns.current_user

    case build_ctx(conv_id, user) do
      {:ok, ctx} ->
        case Mcp.handle(conn.body_params, ctx) do
          :noreply -> send_resp(conn, 202, "")
          resp -> json(conn, resp)
        end

      {:error, status, message} ->
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  defp build_ctx(conv_id, user) do
    case Conversations.get_conversation(conv_id, user.id) do
      %Conversations.Conversation{caller_tools: [_ | _]} = conv ->
        {:ok, %{conversation: conv}}

      %Conversations.Conversation{} ->
        {:error, 404, "no caller tools on this conversation"}

      nil ->
        {:error, 404, "conversation not found"}
    end
  rescue
    Ecto.Query.CastError -> {:error, 404, "conversation not found"}
  end
end
