defmodule FountainBuzz.ContextTest do
  use Fountain.DataCase, async: true
  import FountainBuzz.Factory

  alias Fountain.{Accounts, Crypto, Vaults}
  alias FountainBuzz, as: Buzz
  alias FountainBuzz.Identity

  describe "identities (tenant scoping)" do
    test "create/get/list are scoped to the owner" do
      user = insert_verified_user()
      other = insert_verified_user()
      identity = insert_buzz_identity(%{"user_id" => user.id, "name" => "philo"})

      assert %Identity{name: "philo"} = Buzz.get_identity(identity.id, user.id)
      assert Buzz.get_identity(identity.id, other.id) == nil
      assert [%Identity{id: id}] = Buzz.list_identities(user.id)
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
      assert %Identity{} = insert_buzz_identity(%{"user_id" => other.id, "name" => "dup"})
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

  describe "conversation_mcp_servers/2" do
    test "returns the buzz MCP entry for a Buzz-driven conversation" do
      user = insert_verified_user()
      agent = insert_agent(%{"user_id" => user.id})
      vault = insert_vault(%{"user_id" => user.id})

      insert_buzz_identity(%{
        "user_id" => user.id,
        "agent_id" => agent.id,
        "vault_id" => vault.id
      })

      conv = insert_conversation(user_id: user.id, agent_id: agent.id, vault_id: vault.id)

      assert [entry] = Buzz.conversation_mcp_servers(conv.id, "sprite-tok")
      assert entry.name == "fountain-buzz"
      assert entry.type == "http"
      assert entry.url =~ "/api/mcp/buzz/#{conv.id}"
      assert [%{name: "Authorization", value: "Bearer sprite-tok"}] = entry.headers
    end

    test "returns [] for a non-Buzz conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      assert Buzz.conversation_mcp_servers(conv.id, "tok") == []
    end

    test "returns [] for an unknown conversation or blank token" do
      assert Buzz.conversation_mcp_servers("00000000-0000-0000-0000-000000000000", "tok") == []
      assert Buzz.conversation_mcp_servers("x", "") == []
    end
  end

  describe "provision_identity/2" do
    setup do
      user = insert_verified_user()
      agent = insert_agent(%{"user_id" => user.id})
      pub = String.duplicate("a", 64)

      params = %{
        "name" => "philo",
        "relay_url" => "wss://relay.example",
        "agent_id" => agent.id,
        "pubkey" => pub,
        "private_key_nsec" => "nsec1secret",
        "auth_tag" => "[\"auth\",\"owner\"]",
        "display_name" => "Philo"
      }

      %{user: user, agent: agent, params: params, pub: pub}
    end

    test "creates the vault, secrets and an enabled identity", %{
      user: user,
      params: params,
      pub: pub
    } do
      assert {:ok, identity} = Buzz.provision_identity(user.id, params)
      assert identity.pubkey == pub
      assert identity.enabled

      # The vault holds the BUZZ_* secrets, decryptable server-side.
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      vault = Fountain.Vaults.get_vault(identity.vault_id, user.id)
      env = Fountain.Vaults.decrypted_env(vault, dek)
      assert env["BUZZ_PRIVATE_KEY"] == "nsec1secret"
      assert env["BUZZ_RELAY_URL"] == "wss://relay.example"
    end

    test "converges on the pubkey — a second call returns the same identity, no duplicate", %{
      user: user,
      params: params
    } do
      assert {:ok, first} = Buzz.provision_identity(user.id, params)
      assert {:ok, second} = Buzz.provision_identity(user.id, params)
      assert first.id == second.id
      assert [_only_one] = Buzz.list_identities(user.id)
    end

    test "re-provision refreshes the vault secrets", %{user: user, params: params} do
      {:ok, identity} = Buzz.provision_identity(user.id, params)

      {:ok, _} =
        Buzz.provision_identity(user.id, Map.put(params, "private_key_nsec", "nsec1rotated"))

      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      vault = Fountain.Vaults.get_vault(identity.vault_id, user.id)
      assert Fountain.Vaults.decrypted_env(vault, dek)["BUZZ_PRIVATE_KEY"] == "nsec1rotated"
    end

    test "missing required fields is an error", %{user: user, params: params} do
      assert {:error, {:missing, missing}} =
               Buzz.provision_identity(user.id, Map.delete(params, "private_key_nsec"))

      assert "private_key_nsec" in missing
    end

    # #783: an identity may name the environment its conversations launch
    # under, so one agent config runs under one environment per identity.
    test "stores an environment override, and a re-provision without one clears it", %{
      user: user,
      params: params
    } do
      env = insert_env(user_id: user.id)

      assert {:ok, identity} =
               Buzz.provision_identity(user.id, Map.put(params, "environment_id", env.id))

      assert identity.environment_id == env.id

      # The provider's deploy is the whole truth: omitting it is "none".
      assert {:ok, again} = Buzz.provision_identity(user.id, params)
      assert again.id == identity.id
      assert is_nil(again.environment_id)
    end

    # #790: the author gate the desktop sends rides onto the identity, and an
    # omission means owner-only — the deploy is the whole truth.
    test "stores the author gate, defaulting to owner-only", %{user: user, params: params} do
      pk = String.duplicate("b", 64)

      assert {:ok, identity} =
               Buzz.provision_identity(
                 user.id,
                 Map.merge(params, %{
                   "respond_to" => "allowlist",
                   "respond_to_allowlist" => [" " <> String.upcase(pk) <> " ", pk, ""]
                 })
               )

      assert identity.respond_to == "allowlist"
      # trimmed, lowercased, deduped
      assert identity.respond_to_allowlist == [pk]

      assert {:ok, again} = Buzz.provision_identity(user.id, params)
      assert again.id == identity.id
      assert again.respond_to == "owner-only"
      assert again.respond_to_allowlist == []
    end

    test "allowlist mode with no pubkeys, an unknown mode, or a bad pubkey is refused",
         %{user: user, params: params} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Buzz.provision_identity(user.id, Map.put(params, "respond_to", "allowlist"))

      assert %{respond_to_allowlist: [_]} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} =
               Buzz.provision_identity(user.id, Map.put(params, "respond_to", "everyone"))

      assert %{respond_to: [_]} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} =
               Buzz.provision_identity(
                 user.id,
                 Map.merge(params, %{
                   "respond_to" => "allowlist",
                   "respond_to_allowlist" => ["npub1notahexkey"]
                 })
               )

      assert %{respond_to_allowlist: [_]} = errors_on(cs)
    end

    test "update_access changes only the gate, and refuses an empty or invalid change",
         %{user: user, params: params} do
      {:ok, identity} = Buzz.provision_identity(user.id, params)
      pk = String.duplicate("c", 64)

      assert {:ok, updated} =
               Buzz.update_access(identity, %{
                 "respond_to" => "allowlist",
                 "respond_to_allowlist" => [String.upcase(pk)]
               })

      assert updated.respond_to == "allowlist"
      assert updated.respond_to_allowlist == [pk]
      assert updated.name == identity.name
      assert updated.environment_id == identity.environment_id

      # Only the fields sent change: mode alone keeps the list.
      assert {:ok, again} = Buzz.update_access(updated, %{"respond_to" => "anyone"})
      assert again.respond_to_allowlist == [pk]

      assert {:error, :nothing_to_update} = Buzz.update_access(again, %{})

      assert {:error, %Ecto.Changeset{}} =
               Buzz.update_access(again, %{
                 "respond_to" => "allowlist",
                 "respond_to_allowlist" => []
               })
    end

    # ADR 0023 step 8: an identity may name where its conversations run. It is
    # a launch field like the environment override: stored, cleared when a
    # re-provision omits it, and refused before the vault exists when invalid.
    test "stores a sandbox_mode, and a re-provision without one clears it", %{
      user: user,
      params: params
    } do
      assert {:ok, identity} =
               Buzz.provision_identity(user.id, Map.put(params, "sandbox_mode", "persistent"))

      assert identity.sandbox_mode == "persistent"

      assert {:ok, again} = Buzz.provision_identity(user.id, params)
      assert is_nil(again.sandbox_mode)
    end

    test "an unknown sandbox_mode is refused and nothing is provisioned", %{
      user: user,
      params: params
    } do
      assert {:error, :invalid_sandbox_mode} =
               Buzz.provision_identity(user.id, Map.put(params, "sandbox_mode", "forever"))

      assert is_nil(Buzz.get_identity_by_pubkey(params["pubkey"], user.id))
    end

    test "a foreign or unknown environment_id is not stored", %{user: user, params: params} do
      other = insert_verified_user()
      foreign = insert_env(user_id: other.id)

      assert {:error, :environment_not_found} =
               Buzz.provision_identity(user.id, Map.put(params, "environment_id", foreign.id))

      assert {:error, :environment_not_found} =
               Buzz.provision_identity(
                 user.id,
                 Map.put(params, "environment_id", Ecto.UUID.generate())
               )

      # And nothing was half-created on the way to the refusal.
      assert Buzz.list_identities(user.id) == []
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
      assert env["BUZZ_ACP_BASE_PROMPT_FILE"] =~ "buzz-base-prompt.md"
      assert env["BUZZ_ACP_RELAY_OBSERVER"] == "true"

      # The child authenticates back with a freshly minted key.
      assert env["FOUNTAIN_BASE_URL"] == "https://fountain.example"
      assert String.starts_with?(env["FOUNTAIN_API_KEY"], "ftn_")

      # That key is real, sprite-scoped, and owned by the identity's user.
      assert {:ok, %{id: user_id}, key} = Accounts.authenticate_api_key(env["FOUNTAIN_API_KEY"])
      assert user_id == user.id
      assert key.scopes == ["sprite"]

      # The launch reports the key id so the caller can revoke it on stop.
      assert launch.api_key_id == key.id
      assert launch.command == "/opt/buzz-acp"
    end

    # #783: the override reaches the ACP child as --environment, so every
    # conversation the harness opens is provisioned from it.
    test "an environment override is passed to the ACP child",
         %{identity: identity, agent: agent, vault: vault, user: user} do
      env = insert_env(user_id: user.id)
      {:ok, identity} = Buzz.update_identity(identity, %{"environment_id" => env.id})

      assert {:ok, launch} =
               Buzz.harness_launch(identity,
                 buzz_acp_path: "/opt/buzz-acp",
                 base_url: "https://fountain.example",
                 fountain_bin: "fountain"
               )

      assert Map.new(launch.env)["BUZZ_ACP_AGENT_ARGS"] ==
               "acp,--agent,#{agent.id},--vault,#{vault.id},--environment,#{env.id}"
    end

    # ADR 0023: the mode reaches the ACP child as --sandbox-mode, so every
    # conversation the harness opens lands where the identity says.
    test "a sandbox_mode is passed to the ACP child",
         %{identity: identity, agent: agent, vault: vault} do
      {:ok, identity} = Buzz.update_identity(identity, %{"sandbox_mode" => "persistent"})

      assert {:ok, launch} =
               Buzz.harness_launch(identity,
                 buzz_acp_path: "/opt/buzz-acp",
                 base_url: "https://fountain.example",
                 fountain_bin: "fountain"
               )

      assert Map.new(launch.env)["BUZZ_ACP_AGENT_ARGS"] ==
               "acp,--agent,#{agent.id},--vault,#{vault.id},--sandbox-mode,persistent"
    end

    # #790: without BUZZ_ACP_RESPOND_TO the harness runs owner-only whatever the
    # desktop's record says; the identity's gate must reach the env.
    test "the author gate is set on the harness env",
         %{identity: identity} do
      opts = [buzz_acp_path: "/opt/buzz-acp", base_url: "https://f.example"]

      assert {:ok, launch} = Buzz.harness_launch(identity, opts)
      env = Map.new(launch.env)
      assert env["BUZZ_ACP_RESPOND_TO"] == "owner-only"
      refute Map.has_key?(env, "BUZZ_ACP_RESPOND_TO_ALLOWLIST")

      {:ok, identity} = Buzz.update_identity(identity, %{"respond_to" => "anyone"})
      assert {:ok, launch} = Buzz.harness_launch(identity, opts)
      assert Map.new(launch.env)["BUZZ_ACP_RESPOND_TO"] == "anyone"

      a = String.duplicate("a", 64)
      b = String.duplicate("b", 64)

      {:ok, identity} =
        Buzz.update_identity(identity, %{
          "respond_to" => "allowlist",
          "respond_to_allowlist" => [a, b]
        })

      assert {:ok, launch} = Buzz.harness_launch(identity, opts)
      env = Map.new(launch.env)
      assert env["BUZZ_ACP_RESPOND_TO"] == "allowlist"
      assert env["BUZZ_ACP_RESPOND_TO_ALLOWLIST"] == "#{a},#{b}"
    end

    test "launch_config_changed? spots the fields a running harness was launched with",
         %{identity: identity, user: user} do
      refute Buzz.launch_config_changed?(identity, identity)

      {:ok, gated} = Buzz.update_identity(identity, %{"respond_to" => "anyone"})
      assert Buzz.launch_config_changed?(identity, gated)

      env = insert_env(user_id: user.id)
      {:ok, moved} = Buzz.update_identity(identity, %{"environment_id" => env.id})
      assert Buzz.launch_config_changed?(identity, moved)

      {:ok, homed} = Buzz.update_identity(identity, %{"sandbox_mode" => "persistent"})
      assert Buzz.launch_config_changed?(identity, homed)

      # A field the harness never reads at launch is not a reason to bounce it.
      {:ok, disabled} = Buzz.update_identity(identity, %{"enabled" => false})
      refute Buzz.launch_config_changed?(identity, disabled)
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
