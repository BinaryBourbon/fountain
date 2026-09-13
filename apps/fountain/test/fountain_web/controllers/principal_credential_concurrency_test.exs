defmodule FountainWeb.PrincipalCredentialConcurrencyTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Fountain.Factory
  import FountainWeb.ConnCase
  @endpoint FountainWeb.Endpoint

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.{Audit, Crypto, InferenceCredentials, Principals, Repo}

  for operation <- [:clear, :write] do
    test "principal #{operation} applies to the current default after waiting for source admission" do
      Sandbox.unboxed_run(Repo, fn ->
        app = insert_verified_user(email: "credential-race-#{Ecto.UUID.generate()}@example.com")
        {_, key} = insert_api_key(app)

        {:ok, %{claimable: grant}} =
          Principals.create_claimable(app, %{"application_id" => "credential-race"})

        {:ok, original} = InferenceCredentials.create_set(grant.user_id, "Original")
        {:ok, next} = InferenceCredentials.create_set(grant.user_id, "Next")
        owner = self()

        blocker =
          independent(fn ->
            InferenceCredentials.with_source_lock(grant.user_id, fn ->
              send(owner, :source_locked)

              receive do
                :mutate -> :ok
              after
                5_000 -> raise "mutation barrier was not released"
              end

              case unquote(operation) do
                :clear ->
                  {:ok, _} =
                    Principals.put_inference_credential(
                      grant.id,
                      app.id,
                      :anthropic_api_key,
                      "interleaved-key"
                    )

                :write ->
                  {:ok, _} = InferenceCredentials.set_default(next)
              end

              :ok
            end)
          end)

        try do
          assert_receive :source_locked, 5_000
          assert_receive {:backend, blocker_pid, _}, 5_000
          assert blocker_pid == blocker.pid

          request =
            independent(fn ->
              conn = build_conn() |> authed_with_key(key)
              path = "/api/claimable-users/#{grant.id}/inference-credentials/anthropic_api_key"

              case unquote(operation) do
                :clear -> delete(conn, path)
                :write -> put_json(conn, path, %{"value" => "request-key"})
              end
            end)

          try do
            assert_receive {:backend, request_pid, backend}, 5_000
            assert request_pid == request.pid
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
            send(blocker.pid, :mutate)
            assert :ok = Task.await(blocker)
            assert Task.await(request) |> response(204)
            {:ok, dek} = Crypto.load_tenant_key(grant.user_id)
            assert {:ok, values} = InferenceCredentials.decrypted_for_user(grant.user_id, dek)

            case unquote(operation) do
              :clear ->
                assert values == %{}

                assert [event] =
                         Audit.list_recent_for_user(grant.user_id)
                         |> Enum.filter(&(&1.action == "inference_credential.delete"))

                assert event.metadata["by_account"] == app.id
                assert event.metadata["set_id"] == original.id

              :write ->
                assert values == %{anthropic_api_key: "request-key"}
                assert InferenceCredentials.get_for_user(grant.user_id).id == next.id

                assert InferenceCredentials.get_set(original.id, grant.user_id).anthropic_api_key_ciphertext ==
                         nil
            end
          after
            Task.shutdown(request, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)

          for user_id <- [grant.user_id, app.id] do
            InferenceCredentials.with_source_lock(user_id, fn ->
              Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user_id)])
            end)
          end
        end
      end)
    end
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        result = fun.()
        Fountain.DataCase.drain_best_effort_tasks(self())
        result
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "request did not wait for source admission"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
