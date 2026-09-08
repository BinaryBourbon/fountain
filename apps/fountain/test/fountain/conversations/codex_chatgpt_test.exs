defmodule Fountain.Conversations.CodexChatGPTTest do
  @moduledoc """
  How the grant reaches a codex sandbox (ADR 0047 decision 4): the env entry
  and the `auth.json` Fountain writes instead of running `codex login`.
  `async: false` for the one platform row every test here connects.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.Conversations.{CodexChatGPT, Provisioning}
  alias Managoat.Sandbox.Handle

  @handle %Handle{provider: :fake, name: "sbx"}
  @placeholder "__codex_chatgpt_access_token__"

  test "env/2 exports the grant for codex only, and only when present" do
    creds = %{codex_chatgpt_access_token: @placeholder, openai_api_key: nil}

    assert CodexChatGPT.env(Managoat.Runtimes.Codex, creds) ==
             [{"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}]

    assert CodexChatGPT.env(Managoat.Runtimes.Codex, %{}) == []
    assert CodexChatGPT.env(Managoat.Runtimes.Codex, %{codex_chatgpt_access_token: ""}) == []
    assert CodexChatGPT.env(Managoat.Runtimes.OpenCode, creds) == []
    assert CodexChatGPT.env(nil, creds) == []
  end

  test "prepare_sandbox/3 is :skip for another runtime or a spawn without the grant" do
    assert CodexChatGPT.prepare_sandbox(@handle, "claude", [{"CODEX_CHATGPT_ACCESS_TOKEN", "x"}]) ==
             :skip

    assert CodexChatGPT.prepare_sandbox(@handle, "codex", [{"OPENAI_API_KEY", "sk-x"}]) == :skip

    assert CodexChatGPT.prepare_sandbox(@handle, "codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", ""}]) ==
             :skip
  end

  test "prepare_sandbox/3 writes the chatgptAuthTokens file with the placeholder and the synthesised id_token" do
    connect!()
    test_pid = self()

    expect(Managoat.Sandbox, :exec, fn @handle, "mkdir", ["-p", "/home/sprite/.codex"], _ ->
      {:ok, "", 0}
    end)

    expect(Managoat.Sandbox, :write_file, fn @handle, path, body, opts ->
      send(test_pid, {:written, path, body, opts})
      :ok
    end)

    assert :ok =
             CodexChatGPT.prepare_sandbox(@handle, "codex", [
               {"HOME", "/home/sprite"},
               {"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}
             ])

    assert_receive {:written, "/home/sprite/.codex/auth.json", body, opts}
    assert opts[:mode] == 0o600

    assert %{
             "auth_mode" => "chatgptAuthTokens",
             "tokens" => %{
               "access_token" => @placeholder,
               "refresh_token" => "",
               "account_id" => "acct_platform_1",
               "id_token" => id_token
             },
             "last_refresh" => last_refresh
           } = Jason.decode!(body)

    assert {:ok, %{"account_id" => "acct_platform_1", "email" => nil}} =
             Fountain.PlatformChatGPT.Tokens.claims(id_token)

    assert {:ok, _, _} = DateTime.from_iso8601(last_refresh)
    # Nothing but the placeholder stands where a token would.
    refute body =~ "rt_original"
  end

  test "prepare_sandbox/3 reports a sandbox that refuses the write, and a grant that is gone" do
    connect!()

    expect(Managoat.Sandbox, :exec, fn _, "mkdir", _, _ -> {:ok, "read-only", 1} end)

    assert {:error, {:codex_auth_mkdir, 1, "read-only"}} =
             CodexChatGPT.prepare_sandbox(@handle, "codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", "p"}])

    Fountain.PlatformChatGPT.disconnect()

    assert {:error, :platform_chatgpt_not_connected} =
             CodexChatGPT.prepare_sandbox(@handle, "codex", [{"CODEX_CHATGPT_ACCESS_TOKEN", "p"}])
  end

  test "Provisioning.prepare_runtime_sprite/5 takes the grant path before the library's login" do
    connect!()

    # The library's `prepare_sandbox/3` would spawn `codex login`; on the
    # grant path it is never reached, so a spawn is a failure here.
    reject(&Managoat.Sandbox.spawn/4)
    stub(Fountain.RuntimeDispatch, :install, fn _, "codex", _ -> :ok end)
    expect(Managoat.Sandbox, :exec, fn _, "mkdir", _, _ -> {:ok, "", 0} end)
    expect(Managoat.Sandbox, :write_file, fn _, _, _, _ -> :ok end)

    assert :ok =
             Provisioning.prepare_runtime_sprite(
               @handle,
               "codex",
               Managoat.Runtimes.Codex,
               %{name: "a"},
               [{"CODEX_CHATGPT_ACCESS_TOKEN", @placeholder}]
             )
  end
end
