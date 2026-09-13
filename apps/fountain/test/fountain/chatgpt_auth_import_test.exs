defmodule Fountain.ChatGPTAuthImportTest do
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Repo

  test "rejected auth.json cannot replace a stored platform grant" do
    connect!()
    [stored] = Repo.all(Account)
    file = Jason.decode!(auth_json(%{refresh_token: "replacement-secret"}))

    for rejected <-
          [Map.delete(file, "auth_mode")] ++
            Enum.map([nil, "apikey", "apiKey", "chatgptAuthTokens", "unsupported"], fn mode ->
              Map.put(file, "auth_mode", mode)
            end) do
      assert {:error, :not_a_chatgpt_login} =
               ChatGPTAccounts.platform_connect_from_auth_json(Jason.encode!(rejected))

      assert Repo.all(Account) == [stored]
    end

    assert {:ok, _access} = ChatGPTAccounts.platform_access_token()
  end
end
