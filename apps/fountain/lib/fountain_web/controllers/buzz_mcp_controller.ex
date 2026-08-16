defmodule FountainWeb.BuzzMcpController do
  @moduledoc """
  The MCP endpoint a hosted Buzz agent's sandbox calls to post to its channel
  (ADR 0020 Phase 2, gate #737). Streamable-HTTP transport: one JSON-RPC message
  per POST, a JSON response back (or 202 for a notification).

  The sandbox authenticates with its sprite token (already in it, so no new
  secret leaves the server). This controller verifies the conversation is
  Buzz-driven, resolves the agent's Nostr key **server-side** from the identity's
  vault, and hands `Fountain.Buzz.Mcp` a context that shells out to the baked
  `buzz` CLI — the nsec never enters the sandbox.
  """
  use FountainWeb, :controller

  alias Fountain.{Audit, Buzz, Conversations, Crypto, Vaults}
  alias Fountain.Buzz.Mcp

  @default_buzz_bin "/usr/local/lib/fountain-buzz/buzz"

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

  # Resolve conversation → Buzz identity → vault → nsec, all scoped to the caller.
  defp build_ctx(conv_id, user) do
    with %Conversations.Conversation{} = conv <- get_conv(conv_id, user),
         %Buzz.BuzzIdentity{} = identity <- get_identity(conv, user),
         %Vaults.Vault{} = vault <- get_vault(identity, user),
         {:ok, dek} <- Crypto.load_tenant_key(user.id) do
      env =
        vault
        |> Vaults.decrypted_env(dek)
        |> Enum.filter(fn {k, _} -> String.starts_with?(k, "BUZZ_") end)

      {:ok, %{buzz_bin: buzz_bin(), env: env, audit: audit_fn(identity, user)}}
    else
      {:error, _, _} = err -> err
      :no_conv -> {:error, 404, "conversation not found"}
      :not_buzz -> {:error, 404, "not a buzz conversation"}
      :no_vault -> {:error, 404, "buzz vault not found"}
      _ -> {:error, 500, "could not resolve the buzz identity"}
    end
  end

  defp get_conv(conv_id, user),
    do: Conversations.get_conversation(conv_id, user.id) || :no_conv

  defp get_identity(%{vault_id: nil}, _user), do: :not_buzz

  defp get_identity(%{vault_id: vault_id}, user),
    do: Buzz.get_identity_by_vault(vault_id, user.id) || :not_buzz

  defp get_vault(%Buzz.BuzzIdentity{vault_id: vault_id}, user),
    do: Vaults.get_vault(vault_id, user.id) || :no_vault

  # The publish is an effect, not a tenant-state mutation, so it is audited here
  # rather than in a context. Records what happened and where — never the message
  # content (ADR 0013).
  defp audit_fn(identity, user) do
    fn tool, args ->
      Audit.record(%{
        user_id: user.id,
        action: "buzz.published",
        resource_type: "buzz_identity",
        resource_id: identity.id,
        actor: "sprite",
        metadata:
          %{"tool" => tool}
          |> put_present("channel", args["channel"])
          |> put_present("event", args["event"])
      })
    end
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp buzz_bin, do: Application.get_env(:fountain, :buzz_cli_bin, @default_buzz_bin)
end
