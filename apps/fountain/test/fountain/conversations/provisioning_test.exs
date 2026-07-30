defmodule Fountain.Conversations.ProvisioningTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.Provisioning

  describe "apply_network_policy/3 — limited networking" do
    test "empty allowed_hosts denies by default instead of sending an empty rule list" do
      env = insert_env(%{"networking_type" => "limited", "networking_config" => %{}})
      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        refute policy.rules == [],
               "an empty rules list is Sprites' documented allow-all — limited " <>
                 "with no allowed_hosts must not send that"

        assert %Sprites.Policy{rules: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]} =
                 policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(%{name: "test-sprite"}, env, conv.id)
    end

    test "absent allowed_hosts (no networking_config at all) also denies by default" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        assert %Sprites.Policy{rules: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]} =
                 policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(%{name: "test-sprite"}, env, conv.id)
    end

    test "non-empty allowed_hosts still builds an allowlist" do
      env =
        insert_env(%{
          "networking_type" => "limited",
          "networking_config" => %{"allowed_hosts" => ["github.com", "registry.npmjs.org"]}
        })

      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        assert %Sprites.Policy{
                 rules: [
                   %Sprites.Policy.Rule{domain: "github.com", action: "allow"},
                   %Sprites.Policy.Rule{domain: "registry.npmjs.org", action: "allow"}
                 ]
               } = policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(%{name: "test-sprite"}, env, conv.id)
    end
  end
end
