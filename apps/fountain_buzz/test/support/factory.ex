defmodule FountainBuzz.Factory do
  @moduledoc """
  The extension's own factory helper (ADR 0043, #1507).

  `insert_buzz_identity/1` used to live in `Fountain.Factory`, which is core
  test support and imported by every `DataCase`. It moved here with the context
  it builds rows for: the guard test forbids core naming an extension module,
  and test support is core code like any other.

  It composes with the host's factory rather than replacing it — the user, agent
  and vault it needs are Fountain's, so it imports them.
  """

  import Fountain.Factory

  def insert_buzz_identity(overrides \\ %{}) do
    overrides = string_keys(overrides)

    user_id = Map.get_lazy(overrides, "user_id", fn -> insert_verified_user().id end)

    agent_id =
      Map.get_lazy(overrides, "agent_id", fn -> insert_agent(%{"user_id" => user_id}).id end)

    vault_id =
      Map.get_lazy(overrides, "vault_id", fn -> insert_vault(%{"user_id" => user_id}).id end)

    attrs =
      Map.merge(
        %{
          "user_id" => user_id,
          "agent_id" => agent_id,
          "vault_id" => vault_id,
          "name" => "buzz-#{System.unique_integer([:positive])}",
          "relay_url" => "wss://relay.test"
        },
        overrides
      )

    {:ok, identity} = FountainBuzz.create_identity(attrs)
    identity
  end

  defp string_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp string_keys(list) when is_list(list),
    do: Map.new(list, fn {k, v} -> {to_string(k), v} end)
end
