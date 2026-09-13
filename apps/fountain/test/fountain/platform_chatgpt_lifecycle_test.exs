defmodule Fountain.PlatformChatGPTLifecycleTest do
  # The refresher and shared Req stub are global processes.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.AdminEvent
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account

  test "reconnect changes generation; refresh changes only the write version" do
    first = connect!(%{access_token: access_token(60)})
    assert first.lock_version == 1
    assert {:ok, _} = Ecto.UUID.cast(first.generation)
    stub_refresh()

    assert {:ok, _} = ChatGPTAccounts.platform_access_token()
    refreshed = Repo.get!(Account, first.id)
    assert refreshed.generation == first.generation
    assert refreshed.lock_version == first.lock_version + 1

    replacement = connect!()
    assert replacement.id == first.id
    refute replacement.generation == first.generation
    assert replacement.lock_version == refreshed.lock_version + 1
  end

  test "late terminal refusal cannot revoke a reconnected grant or emit a revocation event" do
    first = connect!(%{access_token: access_token(60)})

    stub_auth(%{
      "/oauth/token" => fn _ ->
        connect!(%{account_id: "replacement", refresh_token: "rt_original"})
        {400, %{"error" => "invalid_grant"}}
      end
    })

    assert {:error, :stale_grant} = ChatGPTAccounts.platform_access_token()
    replacement = Repo.get!(Account, first.id)
    assert replacement.status == "active"
    assert replacement.account_id == "replacement"
    assert replacement.revoked_reason == nil
    assert revoked_events() == []
  end

  test "late refresh success cannot serve or overwrite a different account generation" do
    first = connect!(%{access_token: access_token(60)})
    replacement_token = access_token(7_200, %{"replacement" => true})

    stub_auth(%{
      "/oauth/token" => fn _ ->
        connect!(%{access_token: replacement_token, account_id: "replacement"})
        {200, %{"access_token" => access_token(7_200), "refresh_token" => "late_rotation"}}
      end
    })

    assert {:error, :stale_grant} = ChatGPTAccounts.platform_access_token()
    current = Repo.get!(Account, first.id)
    assert {:ok, ^replacement_token} = Crypto.decrypt_platform(current.access_token_ciphertext)
    assert current.account_id == "replacement"
    assert {:ok, "rt_original"} = Crypto.decrypt_platform(current.refresh_token_ciphertext)
  end

  for response <- [:success, :terminal] do
    test "disconnect fences an in-flight #{response} response" do
      first = connect!(%{access_token: access_token(60)})

      stub_auth(%{
        "/oauth/token" => fn _ ->
          assert :ok = ChatGPTAccounts.platform_disconnect()

          case unquote(response) do
            :success -> {200, %{"access_token" => access_token(), "refresh_token" => "late"}}
            :terminal -> {400, %{"error" => "invalid_grant"}}
          end
        end
      })

      assert {:error, :not_connected} = ChatGPTAccounts.platform_access_token()
      refute Repo.get(Account, first.id)
      assert revoked_events() == []
      replacement = connect!()
      refute replacement.id == first.id
      refute replacement.generation == first.generation
    end
  end

  test "terminal failure advances the write version without replacing the generation" do
    first = connect!(%{access_token: access_token(60)})
    stub_refusal()
    assert {:error, :revoked} = ChatGPTAccounts.platform_access_token()
    current = Repo.get!(Account, first.id)
    assert current.generation == first.generation
    assert current.lock_version == first.lock_version + 1
  end

  for response <- [:success, :terminal] do
    test "a stale #{response} cannot undo a refresh that kept the same refresh token" do
      first = connect!(%{access_token: access_token(60)})
      winner = access_token(7_200, %{"winner" => true})
      counter = start_supervised!({Agent, fn -> 0 end})

      stub_auth(%{
        "/oauth/token" => fn _ ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 ->
              assert {:ok, ^winner} = ChatGPTAccounts.platform_refresh_serialized(:force)

              case unquote(response) do
                :success -> {200, %{"access_token" => access_token(7_200, %{"late" => true})}}
                :terminal -> {400, %{"error" => "invalid_grant"}}
              end

            1 ->
              {200, %{"access_token" => winner}}
          end
        end
      })

      assert {:ok, ^winner} = ChatGPTAccounts.platform_access_token()
      current = Repo.get!(Account, first.id)
      assert current.status == "active"
      assert current.generation == first.generation
      assert current.lock_version == first.lock_version + 1
      assert current.refresh_token_ciphertext == first.refresh_token_ciphertext
      assert {:ok, ^winner} = Crypto.decrypt_platform(current.access_token_ciphertext)
      assert revoked_events() == []
    end
  end

  test "expiry advances the write version without replacing the generation" do
    {:ok, first} =
      ChatGPTAccounts.platform_connect_workspace_token("wst_static", nil, account_id: "acct_ws")

    Repo.get!(Account, first.id)
    |> Ecto.Changeset.change(access_expires_at: seconds_from_now(-60))
    |> Repo.update!()

    assert {:error, :expired} = ChatGPTAccounts.platform_access_token()
    current = Repo.get!(Account, first.id)
    assert current.status == "expired"
    assert current.generation == first.generation
    assert current.lock_version == first.lock_version + 1
  end

  defp seconds_from_now(n),
    do: DateTime.utc_now() |> DateTime.add(n, :second) |> DateTime.truncate(:second)

  defp revoked_events do
    Repo.all(from(e in AdminEvent, where: e.event_type == "admin.platform_chatgpt.revoked"))
  end
end
