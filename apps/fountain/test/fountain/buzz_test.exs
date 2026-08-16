defmodule Fountain.BuzzTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Accounts, Buzz, Crypto, Vaults}
  alias Fountain.Buzz.BuzzIdentity

  describe "identities (tenant scoping)" do
    test "create/get/list are scoped to the owner" do
      user = insert_verified_user()
      other = insert_verified_user()
      identity = insert_buzz_identity(%{"user_id" => user.id, "name" => "philo"})

      assert %BuzzIdentity{name: "philo"} = Buzz.get_identity(identity.id, user.id)
      assert Buzz.get_identity(identity.id, other.id) == nil
      assert [%BuzzIdentity{id: id}] = Buzz.list_identities(user.id)
      assert id == identity.id
      assert Buzz.list_identities(other.id) == []
    end

    test "name is unique per tenant but not across tenants" do
      user = insert_verified_user()
      other = insert_verified_user()
      insert_buzz_identity(%{"user_id" => user.id, "name" => "dup"})

      assert {:error, changeset} =
               Buzz.create_identity(%{
                 "user_id" => user.id,
                 "agent_id" => insert_agent(%{"user_id" => user.id}).id,
                 "vault_id" => insert_vault(%{"user_id" => user.id}).id,
                 "name" => "dup",
                 "relay_url" => "wss://relay.test"
               })

      assert %{name: _} = errors_on(changeset)

      # Same name under a different tenant is fine.
      assert %BuzzIdentity{} = insert_buzz_identity(%{"user_id" => other.id, "name" => "dup"})
    end

    test "rejects a non-ws relay url and a malformed pubkey" do
      user = insert_verified_user()

      base = %{
        "user_id" => user.id,
        "agent_id" => insert_agent(%{"user_id" => user.id}).id,
        "vault_id" => insert_vault(%{"user_id" => user.id}).id,
        "name" => "bad"
      }

      assert {:error, cs} = Buzz.create_identity(Map.put(base, "relay_url", "https://relay.test"))
      assert %{relay_url: _} = errors_on(cs)

      assert {:error, cs2} =
               Buzz.create_identity(
                 base
                 |> Map.put("relay_url", "wss://relay.test")
                 |> Map.put("pubkey", "NOTHEX")
               )

      assert %{pubkey: _} = errors_on(cs2)
    end

    test "mutations leave an audit trail" do
      user = insert_verified_user()
      identity = insert_buzz_identity(%{"user_id" => user.id})

      {:ok, _} = Buzz.update_identity(identity, %{"display_name" => "Philo"})
      {:ok, _} = Buzz.delete_identity(identity)

      actions =
        Fountain.Audit.list_recent_for_user(user.id, 200)
        |> Enum.map(& &1.action)

      assert "buzz_identity.created" in actions
      assert "buzz_identity.updated" in actions
      assert "buzz_identity.deleted" in actions
    end

    test "_unsafe_list_enabled_identities returns only enabled ones, across tenants" do
      a = insert_buzz_identity(%{"enabled" => true})
      b = insert_buzz_identity(%{"enabled" => true})
      _disabled = insert_buzz_identity(%{"enabled" => false})

      ids = Buzz._unsafe_list_enabled_identities() |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.member?(ids, a.id)
      assert MapSet.member?(ids, b.id)
      refute Enum.any?(Buzz._unsafe_list_enabled_identities(), &(&1.enabled == false))
    end
  end

  describe "harness_launch/2" do
    setup do
      user = insert_verified_user()
      agent = insert_agent(%{"user_id" => user.id})
      vault = insert_vault(%{"user_id" => user.id})

      # BUZZ_* secrets live in the vault, decrypted server-side by the launch.
      {:ok, dek} = Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "BUZZ_PRIVATE_KEY", "value" => "nsec1secret"}, dek)

      {:ok, _} =
        Vaults.upsert_secret(
          vault,
          %{"key" => "BUZZ_AUTH_TAG", "value" => "[\"auth\",\"owner\"]"},
          dek
        )

      identity =
        insert_buzz_identity(%{
          "user_id" => user.id,
          "agent_id" => agent.id,
          "vault_id" => vault.id,
          "name" => "philo",
          "relay_url" => "wss://relay.example",
          "display_name" => "Philo"
        })

      %{user: user, agent: agent, vault: vault, identity: identity}
    end

    test "assembles the env: vault secrets, ACP wiring, and a minted FOUNTAIN_API_KEY",
         %{identity: identity, agent: agent, vault: vault, user: user} do
      assert {:ok, launch} =
               Buzz.harness_launch(identity,
                 buzz_acp_path: "/opt/buzz-acp",
                 base_url: "https://fountain.example",
                 fountain_bin: "/usr/local/bin/fountain"
               )

      env = Map.new(launch.env)

      # From the vault, decrypted here — never from the identity row.
      assert env["BUZZ_PRIVATE_KEY"] == "nsec1secret"
      assert env["BUZZ_AUTH_TAG"] == "[\"auth\",\"owner\"]"

      # Identity is authoritative for the relay and display name.
      assert env["BUZZ_RELAY_URL"] == "wss://relay.example"
      assert env["BUZZ_ACP_DISPLAY_NAME"] == "Philo"

      # ACP child points at this agent + vault, pool of one.
      assert env["BUZZ_ACP_AGENT_COMMAND"] == "/usr/local/bin/fountain"
      assert env["BUZZ_ACP_AGENT_ARGS"] == "acp,--agent,#{agent.id},--vault,#{vault.id}"
      assert env["BUZZ_ACP_AGENTS"] == "1"

      # The child authenticates back with a freshly minted key.
      assert env["FOUNTAIN_BASE_URL"] == "https://fountain.example"
      assert String.starts_with?(env["FOUNTAIN_API_KEY"], "ftn_")

      # That key is real, sprite-scoped, and owned by the identity's user.
      assert {:ok, ^user, key} = Accounts.authenticate_api_key(env["FOUNTAIN_API_KEY"])
      assert key.scopes == ["sprite"]

      # The launch reports the key id so the caller can revoke it on stop.
      assert launch.api_key_id == key.id
      assert launch.command == "/opt/buzz-acp"
    end

    test "the identity's relay_url overrides a BUZZ_RELAY_URL in the vault",
         %{identity: identity, vault: vault, user: user} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "BUZZ_RELAY_URL", "value" => "wss://stale"}, dek)

      assert {:ok, launch} =
               Buzz.harness_launch(identity,
                 buzz_acp_path: "/opt/buzz-acp",
                 base_url: "https://f.example"
               )

      assert Map.new(launch.env)["BUZZ_RELAY_URL"] == "wss://relay.example"
    end

    test "revoke_launch_key revokes the minted key", %{identity: identity} do
      {:ok, launch} =
        Buzz.harness_launch(identity,
          buzz_acp_path: "/opt/buzz-acp",
          base_url: "https://f.example"
        )

      assert {:ok, revoked} = Buzz.revoke_launch_key(identity, launch.api_key_id)
      assert revoked.revoked_at != nil
    end

    test "errors when the binary path or base url is missing", %{identity: identity} do
      assert {:error, :no_buzz_acp_path} =
               Buzz.harness_launch(identity, base_url: "https://f.example")

      assert {:error, :no_base_url} =
               Buzz.harness_launch(identity, buzz_acp_path: "/opt/buzz-acp")
    end
  end
end
