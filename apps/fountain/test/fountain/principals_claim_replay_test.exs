defmodule Fountain.PrincipalsClaimReplayTest do
  # Real independent transactions must see committed fixtures. Keep them out
  # of concurrent DataCase suites and delete only this test's accounts.
  use ExUnit.Case, async: false
  use Mimic

  import Ecto.Query
  import Fountain.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Accounts
  alias Fountain.Accounts.{ApiKey, User}
  alias Fountain.Principals
  alias Fountain.Principals.ClaimableUser
  alias Fountain.Repo

  test "a create replay cannot mint application credentials after a claim revokes them" do
    {application, claimer, grant} =
      Sandbox.unboxed_run(Repo, fn ->
        application = insert_verified_user()
        claimer = insert_verified_user()

        {:ok, grant} =
          Principals.create_claimable(application, %{"application_id" => "race"},
            idempotency_key: "claim-replay-race"
          )

        {application, claimer, grant}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = [grant.claimable.user_id, application.id, claimer.id]
        Repo.delete_all(from u in User, where: u.id in ^ids)
      end)
    end)

    parent = self()

    claim =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            result = Principals.claim(grant.claimable.id, grant.claim_token, claimer)
            send(parent, {:claim_before_commit, result})

            receive do
              :commit -> result
            after
              10_000 -> Repo.rollback(:test_commit_timeout)
            end
          end)
        end)
      end)

    assert_receive {:claim_before_commit, {:ok, claimed}}, 5_000

    replay =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:replay_backend, backend})

          Principals.create_claimable(application, %{"application_id" => "race"},
            idempotency_key: "claim-replay-race"
          )
        end)
      end)

    try do
      assert_receive {:replay_backend, backend}, 5_000
      assert waits_for_lock?(backend, System.monotonic_time(:millisecond) + 5_000)
      send(claim.pid, :commit)
      assert {:ok, {:ok, ^claimed}} = Task.await(claim, 5_000)
      assert {:error, :already_claimed} = Task.await(replay, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.get!(ClaimableUser, grant.claimable.id).claim_token_hash == nil
        assert {:ok, _, _} = Accounts.authenticate_api_key(claimed.api_key)
        assert {:error, _} = Accounts.authenticate_api_key(grant.api_key)

        keys =
          Repo.all(
            from k in ApiKey,
              where: k.user_id == ^grant.claimable.user_id and is_nil(k.revoked_at)
          )

        assert length(keys) == 1
      end)
    after
      send(claim.pid, :commit)
      Task.shutdown(claim, :brutal_kill)
      Task.shutdown(replay, :brutal_kill)
    end
  end

  test "credential audit runs after commit and cannot abort the credential transaction" do
    application = Sandbox.unboxed_run(Repo, fn -> insert_verified_user() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        principal_ids =
          Repo.all(
            from c in ClaimableUser,
              where: c.application_user_id == ^application.id,
              select: c.user_id
          )

        Repo.delete_all(from u in User, where: u.id in ^[application.id | principal_ids])
      end)
    end)

    stub(Fountain.Audit, :record, fn attrs ->
      if attrs.action == "api_key.created" do
        refute Repo.in_transaction?()
        # The real audit recorder rescues a failed insert. That must not
        # invalidate the transaction that committed the working credentials.
        {:error, :audit_unavailable}
      else
        Mimic.call_original(Fountain.Audit, :record, [attrs])
      end
    end)

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, first} =
               Principals.create_claimable(application, %{"application_id" => "audit"},
                 idempotency_key: "audit"
               )

      assert {:ok, replay} =
               Principals.create_claimable(application, %{"application_id" => "audit"},
                 idempotency_key: "audit"
               )

      assert first.claimable.id == replay.claimable.id
      assert {:ok, _, _} = Accounts.authenticate_api_key(replay.api_key)
      assert Repo.get!(ClaimableUser, replay.claimable.id).claim_token_hash
    end)
  end

  defp waits_for_lock?(backend, deadline) do
    waiting =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows == [[true]]
      end)

    cond do
      waiting ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        waits_for_lock?(backend, deadline)
    end
  end
end
