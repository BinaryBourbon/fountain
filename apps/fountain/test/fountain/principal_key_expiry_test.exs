defmodule Fountain.PrincipalKeyExpiryTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey

  test "a legacy writer's principal key with no expiry receives 30 days" do
    user = insert_verified_user()
    {:ok, {key, raw}} = Accounts.create_api_key(user.id, "legacy", scopes: ["principal"])

    # The old issuer did not send an expiry or request that generated value
    # back. Authentication and management read the persisted deadline.
    persisted = Repo.reload!(key)
    assert_deadline(persisted)
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

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(set: [scopes: ["principal"]])

    assert_deadline(Repo.reload!(key))

    from(k in ApiKey, where: k.id == ^key.id)
    |> Repo.update_all(set: [expires_at: nil])

    assert_deadline(Repo.reload!(key))
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

  defp assert_deadline(key) do
    assert %DateTime{} = key.expires_at
    remaining = DateTime.diff(key.expires_at, DateTime.utc_now(), :second)
    assert remaining in (30 * 86_400 - 5)..(30 * 86_400)
  end
end
