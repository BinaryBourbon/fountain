defmodule FountainWeb.TeamCommsMcpController do
  @moduledoc """
  The MCP endpoint a teammate's sandbox calls to use its email address and
  phone number (flag `team_comms`). Streamable-HTTP transport: one JSON-RPC
  message per POST, a JSON response back (or 202 for a notification) — the
  same shape as `FountainWeb.BuzzMcpController`.

  The sandbox authenticates with its sprite token (already in it, so no new
  secret leaves the server). This controller checks the conversation is the
  caller's and a teammate's, that the teammate has a contact and the feature
  is available to the caller, and hands `Fountain.Team.Comms.Mcp` a context
  that talks to AgentMail/AgentPhone under Fountain's keys — which never
  enter the sandbox.
  """
  use FountainWeb, :controller

  alias Fountain.{Audit, Conversations}
  alias Fountain.Team.Comms
  alias Fountain.Team.Comms.Mcp

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
    with %Conversations.Conversation{} = conv <- get_conv(conv_id, user),
         {:ok, contact} <- Comms.contact_for_conversation(conv, user.id) do
      {:ok, %{contact: contact, audit: audit_fn(contact, user)}}
    else
      :no_conv -> {:error, 404, "conversation not found"}
      {:error, :not_team} -> {:error, 404, "not a teammate's conversation"}
      {:error, :no_contact} -> {:error, 404, "this teammate has no email address or phone number"}
      {:error, :unavailable} -> {:error, 403, "teammate email and phone are not available here"}
    end
  end

  defp get_conv(conv_id, user),
    do: Conversations.get_conversation(conv_id, user.id) || :no_conv

  # A send is an effect, not a tenant-state mutation, so it is audited here
  # rather than in a context. Records what happened — never the recipients,
  # the subject or the body (ADR 0013).
  defp audit_fn(contact, user) do
    fn tool, summary ->
      Audit.record(%{
        user_id: user.id,
        action: "team.contact.sent",
        resource_type: "team_contact",
        resource_id: contact.id,
        actor: "sprite",
        metadata: Map.merge(%{"tool" => tool, "agent_id" => contact.agent_id}, summary)
      })
    end
  end
end
