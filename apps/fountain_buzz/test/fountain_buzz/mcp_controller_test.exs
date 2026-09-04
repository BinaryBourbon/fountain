defmodule FountainBuzz.McpControllerTest do
  use FountainWeb.ConnCase, async: true
  import FountainBuzz.Factory

  alias Fountain.{Crypto, Vaults}

  setup do
    user = insert_verified_user()
    {_rec, raw_key} = insert_api_key(user)
    %{user: user, raw_key: raw_key}
  end

  # A conversation whose vault is a Identity vault → a "buzz-driven" conv.
  defp buzz_conversation(user) do
    agent = insert_agent(user_id: user.id)
    vault = insert_vault(user_id: user.id)
    {:ok, dek} = Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Vaults.upsert_secret(vault, %{"key" => "BUZZ_PRIVATE_KEY", "value" => "nsec1x"}, dek)

    insert_buzz_identity(%{"user_id" => user.id, "agent_id" => agent.id, "vault_id" => vault.id})
    insert_conversation(user_id: user.id, agent_id: agent.id, vault_id: vault.id)
  end

  defp rpc(conn, raw_key, conv_id, body) do
    conn
    |> authed_with_key(raw_key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/mcp/buzz/#{conv_id}", body)
  end

  test "initialize on a buzz conversation returns the server info", %{
    conn: conn,
    user: user,
    raw_key: raw_key
  } do
    conv = buzz_conversation(user)
    conn = rpc(conn, raw_key, conv.id, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

    body = json_response(conn, 200)
    assert body["result"]["serverInfo"]["name"] == "fountain-buzz"
  end

  test "tools/list advertises the reply tools", %{conn: conn, user: user, raw_key: raw_key} do
    conv = buzz_conversation(user)
    conn = rpc(conn, raw_key, conv.id, %{"id" => 2, "method" => "tools/list"})

    names = json_response(conn, 200)["result"]["tools"] |> Enum.map(& &1["name"])
    assert "buzz_send_message" in names
    assert "buzz_react" in names
  end

  test "tools/call shells out to the configured buzz and audits", %{
    conn: conn,
    user: user,
    raw_key: raw_key
  } do
    # Point the controller at a fake `buzz` that echoes JSON, so the full path
    # (controller → Mcp → System.cmd) runs without the real binary.
    dir = Fountain.TmpDir.mkdir!("buzzbin")
    fake = Path.join(dir, "buzz")
    File.write!(fake, "#!/bin/sh\necho '{\"accepted\":true,\"event_id\":\"e1\"}'\n")
    File.chmod!(fake, 0o755)
    prev = Application.get_env(:fountain_buzz, :buzz_cli_bin)
    Application.put_env(:fountain_buzz, :buzz_cli_bin, fake)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fountain_buzz, :buzz_cli_bin, prev),
        else: Application.delete_env(:fountain_buzz, :buzz_cli_bin)

      File.rm_rf(dir)
    end)

    conv = buzz_conversation(user)

    body = %{
      "id" => 3,
      "method" => "tools/call",
      "params" => %{
        "name" => "buzz_send_message",
        "arguments" => %{"channel" => "chan-1", "content" => "hi from the agent"}
      }
    }

    conn = rpc(conn, raw_key, conv.id, body)
    result = json_response(conn, 200)["result"]
    assert result["isError"] == false
    assert [%{"type" => "text", "text" => out}] = result["content"]
    assert out =~ "accepted"

    actions = Fountain.Audit.list_recent_for_user(user.id, 50) |> Enum.map(& &1.action)
    assert "buzz.published" in actions
  end

  test "a notification gets 202 and no body", %{conn: conn, user: user, raw_key: raw_key} do
    conv = buzz_conversation(user)
    conn = rpc(conn, raw_key, conv.id, %{"method" => "notifications/initialized"})
    assert response(conn, 202) == ""
  end

  test "a non-buzz conversation is 404", %{conn: conn, user: user, raw_key: raw_key} do
    plain = insert_conversation(user_id: user.id)
    conn = rpc(conn, raw_key, plain.id, %{"id" => 1, "method" => "initialize"})
    assert json_response(conn, 404)["error"] =~ "buzz"
  end

  test "another tenant's conversation is 404 (tenant scoping)", %{conn: conn, raw_key: raw_key} do
    other = insert_verified_user()
    conv = buzz_conversation(other)
    conn = rpc(conn, raw_key, conv.id, %{"id" => 1, "method" => "initialize"})
    assert json_response(conn, 404)
  end
end
