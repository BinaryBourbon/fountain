defmodule Fountain.PrincipalKeyExpiryTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey

  test "a legacy writer's principal key with no expiry receives 30 days" do
    user = insert_verified_user()
    earliest = database_deadline()
    {:ok, {key, raw}} = Accounts.create_api_key(user.id, "legacy", scopes: ["principal"])

    # The old issuer did not send an expiry or request that generated value
    # back. Authentication and management read the persisted deadline.
    persisted = Repo.reload!(key)
    assert_deadline(persisted, earliest)
    assert {:ok, _, authenticated} = Accounts.authenticate_api_key(raw)
    assert authenticated.expires_at == persisted.expires_at
  end

  test "explicit principal deadlines and unbounded non-principal keys are preserved" do
    user = insert_verified_user()
    deadline = DateTime.utc_now() |> DateTime.add(60) |> DateTime.truncate(:second)

    {:ok, {key, _}} =
      Accounts.create_api_key(user.id, "anonymous", scopes: ["principal"], expires_at: deadline)

    assert Repo.reload!(key).expires_at == deadline

    for scope <- ["full", "sprite"] do
      {:ok, {other, _}} = Accounts.create_api_key(user.id, scope, scopes: [scope])
      assert is_nil(Repo.reload!(other).expires_at)
    end
  end

  test "an old update cannot clear a principal deadline or add principal scope without one" do
    user = insert_verified_user()
    {:ok, {key, _}} = Accounts.create_api_key(user.id, "changed")

    earliest = database_deadline()

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(set: [scopes: ["principal"]])

    assert_deadline(Repo.reload!(key), earliest)
    earliest = database_deadline()

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(set: [expires_at: nil])

    assert_deadline(Repo.reload!(key), earliest)
  end

  test "ordinary key use does not extend an expired principal credential" do
    user = insert_verified_user()
    past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    {:ok, {key, raw}} =
      Accounts.create_api_key(user.id, "expired", scopes: ["principal"], expires_at: past)

    Accounts.touch_api_key(raw)
    assert Repo.reload!(key).expires_at == past
    assert {:error, :expired} = Accounts.authenticate_api_key(raw)
  end

  test "a legacy write gets its full window even in an older transaction" do
    user = insert_verified_user()
    # Advance beyond the transaction's timestamp(0) second. This is the clock
    # behavior under test, not a wait for an asynchronous side effect.
    Repo.query!("SELECT pg_sleep(1.1)")
    earliest = database_deadline()
    {:ok, {key, _}} = Accounts.create_api_key(user.id, "delayed", scopes: ["principal"])

    assert_deadline(Repo.reload!(key), earliest)
  end

  defp database_deadline do
    %{rows: [[deadline]]} =
      Repo.query!("""
      SELECT date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC') + INTERVAL '30 days'
      """)

    DateTime.from_naive!(deadline, "Etc/UTC")
  end

  defp assert_deadline(key, earliest) do
    latest = database_deadline()
    assert %DateTime{} = key.expires_at
    assert DateTime.compare(key.expires_at, earliest) in [:eq, :gt]
    assert DateTime.compare(key.expires_at, latest) in [:eq, :lt]
  end
end
