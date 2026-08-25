defmodule Fountain.Workers.BrokerVaultReaperTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Broker
  alias Fountain.Workers.BrokerVaultReaper

  setup do
    previous =
      for k <- [:broker_url, :broker_token, :broker_proxy_url],
          do: {k, Application.get_env(:fountain, k)}

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(is_nil(v),
              do: Application.delete_env(:fountain, k),
              else: Application.put_env(:fountain, k, v)
            )
    end)

    :ok
  end

  test "a no-op with the broker off" do
    Application.delete_env(:fountain, :broker_url)
    reject(Broker, :list_vaults, 0)
    assert %{deleted: 0, failed: 0, kept: 0} = BrokerVaultReaper.run()
  end

  test "deletes vaults of conversations ended past retention, and orphans; keeps the rest" do
    Application.put_env(:fountain, :broker_url, "http://broker.test:14321")
    Application.put_env(:fountain, :broker_token, "t")
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    user = insert_verified_user()
    now = ~U[2026-08-25 12:00:00Z]
    old = DateTime.add(now, -200 * 3600, :second)

    ended_long_ago = insert_conversation(user_id: user.id, status: "terminated")

    Repo.update_all(
      from(c in Fountain.Conversations.Conversation, where: c.id == ^ended_long_ago.id),
      set: [updated_at: old]
    )

    ended_recently = insert_conversation(user_id: user.id, status: "failed")
    running = insert_conversation(user_id: user.id, status: "running")

    Repo.update_all(from(c in Fountain.Conversations.Conversation, where: c.id == ^running.id),
      set: [updated_at: old]
    )

    orphan = Broker.vault_name(Ecto.UUID.generate())

    test = self()

    stub(Broker, :delete_vault, fn v ->
      send(test, {:deleted, v})
      :ok
    end)

    vaults = [
      "default",
      Broker.vault_name(ended_long_ago.id),
      Broker.vault_name(ended_recently.id),
      Broker.vault_name(running.id),
      orphan
    ]

    assert %{deleted: 2, failed: 0, kept: 2} = BrokerVaultReaper.run(now: now, vaults: vaults)

    assert_received {:deleted, v1}
    assert_received {:deleted, v2}
    assert Enum.sort([v1, v2]) == Enum.sort([Broker.vault_name(ended_long_ago.id), orphan])
    refute_received {:deleted, _}
  end
end
