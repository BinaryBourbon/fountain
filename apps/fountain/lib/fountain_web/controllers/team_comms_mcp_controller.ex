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
  #
  # The same callback meters it. AgentMail and AgentPhone charge per message
  # on top of the monthly cost of the inbox and the number, so a send is the
  # one comms event with a variable price, and the finance panel could not
  # price it from the contact rows alone. Both calls are best-effort by
  # contract and neither can fail the send.
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

      meter(tool, contact, user, summary)
    end
  end

  # Only the tools that actually put a message on the wire. `audit` is called
  # for those alone today, so the fallback clause is a guard against a future
  # tool joining the audit path without joining the rate card.
  defp meter(tool, contact, user, summary) when tool in ~w(email_send email_reply) do
    record_message(user, contact, "comms_email_sent", %{
      "tool" => tool,
      "recipients" => Map.get(summary, "recipients", 1)
    })
  end

  defp meter("sms_send", contact, user, _summary) do
    record_message(user, contact, "comms_sms_sent", %{"tool" => "sms_send"})
  end

  defp meter(_tool, _contact, _user, _summary), do: :ok

  defp record_message(user, contact, event_type, metadata) do
    Fountain.Billing.record_usage(
      user.id,
      event_type,
      contact.id,
      "team_contact",
      Map.put(metadata, "agent_id", contact.agent_id)
    )
  end
end
