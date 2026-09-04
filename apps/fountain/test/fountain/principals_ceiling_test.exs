defmodule Fountain.PrincipalsCeilingTest do
  @moduledoc """
  The two abuse ceilings on opening a claimable principal (ADR 0044).

  `async: false`, in a module of its own, because both tests hold
  `config :fountain, Fountain.Principals` — global application env that
  `Fountain.Principals.settings/0` reads on every create. An async module
  holding it would change the limits for whatever ran beside it, which is what
  `Fountain.AsyncGlobalConfigGuardrailTest` exists to stop. ExUnit runs every
  async module before the sync ones, so a sync module cannot overlap one; that
  is the whole fix, and the reason this is a separate file rather than a lock.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Principals

  setup do
    on_exit(fn -> Application.delete_env(:fountain, Fountain.Principals) end)
    :ok
  end

  defp put_settings(overrides) do
    Application.put_env(:fountain, Fountain.Principals, overrides)
  end

  defp open(app) do
    {:ok, result} = Principals.create_claimable(app, %{"application_id" => "paddock"})
    result
  end

  test "the outstanding ceiling refuses a runaway application" do
    app = insert_verified_user()
    put_settings(max_outstanding_per_application: 1)

    open(app)

    assert {:error, :too_many_outstanding_principals} =
             Principals.create_claimable(app, %{"application_id" => "paddock"})
  end

  test "a claimed principal stops counting against the outstanding ceiling" do
    app = insert_verified_user()
    put_settings(max_outstanding_per_application: 1)

    %{claimable: c, claim_token: token} = open(app)
    {:ok, _} = Principals.claim(c.id, token, insert_verified_user())

    # The ceiling bounds anonymous grants nobody has taken responsibility for,
    # not machines that now have an owner paying for them.
    assert {:ok, _} = Principals.create_claimable(app, %{"application_id" => "paddock"})
  end

  test "the hourly rate limit refuses a burst" do
    app = insert_verified_user()
    put_settings(max_created_per_hour: 1)

    open(app)

    assert {:error, :principal_rate_limited} =
             Principals.create_claimable(app, %{"application_id" => "paddock"})
  end

  test "the ceilings do not apply to an idempotent replay" do
    app = insert_verified_user()
    put_settings(max_outstanding_per_application: 1, max_created_per_hour: 1)

    {:ok, first} =
      Principals.create_claimable(app, %{"application_id" => "paddock"},
        idempotency_key: "pdk_ceiling"
      )

    # A replay opens nothing, so refusing it would turn a lost response into a
    # dead principal the application can never reach again.
    {:ok, second} =
      Principals.create_claimable(app, %{"application_id" => "paddock"},
        idempotency_key: "pdk_ceiling"
      )

    assert first.claimable.id == second.claimable.id
  end
end
