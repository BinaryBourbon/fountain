defmodule Fountain.PrincipalInferenceCredentialRaceTest do
  use ExUnit.Case, async: false
  use Mimic

  import Ecto.Query
  import Fountain.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.{Crypto, InferenceCredentials, Principals, Repo}
  alias Fountain.Accounts.User

  setup do
    fixtures =
      Sandbox.unboxed_run(Repo, fn ->
        application = insert_verified_user()
        claimer = insert_verified_user()

        {:ok, grant} =
          Principals.create_claimable(application, %{"application_id" => "credential-race"})

        {:ok, _} =
          Principals.put_inference_credential(
            grant.claimable.id,
            application.id,
            :anthropic_api_key,
            "original"
          )

        %{application: application, claimer: claimer, grant: grant}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = [fixtures.grant.claimable.user_id, fixtures.application.id, fixtures.claimer.id]
        Repo.delete_all(from u in User, where: u.id in ^ids)
      end)
    end)

    fixtures
  end

  for value <- ["replacement", nil] do
    test "a claim in progress denies the former owner's #{inspect(value)} mutation", %{
      application: application,
      claimer: claimer,
      grant: grant
    } do
      parent = self()

      claim =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              {:ok, result} = Principals.claim(grant.claimable.id, grant.claim_token, claimer)
              send(parent, :claim_locked)

              receive do
                :commit -> result
              after
                10_000 -> Repo.rollback(:test_timeout)
              end
            end)
          end)
        end)

      assert_receive :claim_locked, 5_000

      writer =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:writer_backend, backend})

            Principals.put_inference_credential(
              grant.claimable.id,
              application.id,
              :anthropic_api_key,
              unquote(value)
            )
          end)
        end)

      try do
        assert_receive {:writer_backend, backend}, 5_000
        assert waits_for_lock?(backend, System.monotonic_time(:millisecond) + 5_000)
        send(claim.pid, :commit)
        assert {:ok, _} = Task.await(claim, 5_000)
        assert {:error, :not_found} = Task.await(writer, 5_000)

        Sandbox.unboxed_run(Repo, fn ->
          {:ok, dek} = Crypto.load_tenant_key(grant.claimable.user_id)

          assert {:ok, %{anthropic_api_key: "original"}} =
                   InferenceCredentials.decrypted_for_user(grant.claimable.user_id, dek)
        end)
      after
        send(claim.pid, :commit)
        Task.shutdown(claim, :brutal_kill)
        Task.shutdown(writer, :brutal_kill)
      end
    end
  end

  test "credential audit failure occurs after commit and preserves the write", %{
    application: application,
    grant: grant
  } do
    stub(Fountain.Audit, :record, fn attrs ->
      if attrs.action == "inference_credential.write" do
        refute Repo.in_transaction?()
        {:error, :audit_unavailable}
      else
        Mimic.call_original(Fountain.Audit, :record, [attrs])
      end
    end)

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} =
               Principals.put_inference_credential(
                 grant.claimable.id,
                 application.id,
                 :anthropic_api_key,
                 "committed"
               )

      {:ok, dek} = Crypto.load_tenant_key(grant.claimable.user_id)

      assert {:ok, %{anthropic_api_key: "committed"}} =
               InferenceCredentials.decrypted_for_user(grant.claimable.user_id, dek)
    end)
  end

  defp waits_for_lock?(backend, deadline) do
    waiting =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [
          backend
        ]).rows == [[true]]
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
