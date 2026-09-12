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

  test "concurrent claim replays leave one principal credential" do
    assert_one_credential_after_rotation(:replay)
  end

  test "owner renewal and claim replay serialize their credential replacement" do
    assert_one_credential_after_rotation(:renewal)
  end

  defp assert_one_credential_after_rotation(second_operation) do
    {application, owner, opened, first} =
      Sandbox.unboxed_run(Repo, fn ->
        application = insert_verified_user()
        owner = insert_verified_user()

        {:ok, opened} =
          Principals.create_claimable(application, %{"application_id" => "rotation"})

        {:ok, first} =
          Principals.claim(opened.claimable.id, opened.claim_token, owner,
            idempotency_key: "rotate"
          )

        {application, owner, opened, first}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = [application.id, owner.id, opened.claimable.user_id]
        Repo.delete_all(from u in User, where: u.id in ^ids)
      end)
    end)

    parent = self()

    blocker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from c in ClaimableUser, where: c.id == ^opened.claimable.id, lock: "FOR UPDATE"
            )

            send(parent, :locked)

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:test_release_timeout)
            end
          end)
        end)
      end)

    assert_receive :locked, 5_000

    replays =
      for operation <- [:replay, second_operation] do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:rotation_backend, backend})

            case operation do
              :replay ->
                Principals.claim(opened.claimable.id, "", owner, idempotency_key: "rotate")

              :renewal ->
                with {:ok, {_key, raw}} <-
                       Principals.renew_owned_credential(owner.id, opened.claimable.user_id) do
                  {:ok, %{api_key: raw}}
                end
            end
          end)
        end)
      end

    try do
      for _ <- replays do
        assert_receive {:rotation_backend, backend}, 5_000
        assert waits_for_lock?(backend, System.monotonic_time(:millisecond) + 5_000)
      end

      send(blocker.pid, :release)
      assert {:ok, :ok} = Task.await(blocker, 5_000)

      results =
        Enum.map(replays, fn task ->
          assert {:ok, result} = Task.await(task, 5_000)
          result
        end)

      Sandbox.unboxed_run(Repo, fn ->
        assert {:error, :revoked} = Accounts.authenticate_api_key(first.api_key)

        assert Enum.count(
                 results,
                 &match?({:ok, _, _}, Accounts.authenticate_api_key(&1.api_key))
               ) == 1

        assert Repo.aggregate(
                 from(k in ApiKey,
                   where:
                     k.user_id == ^opened.claimable.user_id and "principal" in k.scopes and
                       is_nil(k.revoked_at)
                 ),
                 :count
               ) == 1
      end)
    after
      send(blocker.pid, :release)
      Task.shutdown(blocker, :brutal_kill)
      Enum.each(replays, &Task.shutdown(&1, :brutal_kill))
    end
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
