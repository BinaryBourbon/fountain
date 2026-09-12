defmodule Fountain.Conversations.SandboxIdentityTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{Sandbox, SandboxIdentity}
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "starting")
    handle = %Handle{provider: :sprites, name: sandbox.sprite_name}
    %{sandbox: sandbox, handle: handle}
  end

  test "records control metadata outside database locks and ignores handle private data", c do
    id = Ecto.UUID.generate()

    expect(Managoat.Sandbox.Sprites, :get, fn handle ->
      refute Repo.in_transaction?()
      assert handle.name == c.sandbox.sprite_name
      {:ok, %{raw: %{"name" => handle.name, "id" => id}}}
    end)

    handle = %{c.handle | private: %{id: "worker-chosen"}}
    assert {:ok, bound} = SandboxIdentity._unsafe_capture(c.sandbox, handle)
    assert bound.provider_instance_id == id
    assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == id
  end

  test "an outer transaction is refused before provider I/O or a binding write", c do
    reject(Managoat.Sandbox.Sprites, :get, 1)

    assert {:ok, :unchanged} =
             Repo.transaction(fn ->
               assert {:error, :transaction_open} =
                        SandboxIdentity._unsafe_capture(c.sandbox, c.handle)

               assert {:error, :transaction_open} =
                        SandboxIdentity._unsafe_bind(c.sandbox, "trusted")

               assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == nil
               :unchanged
             end)
  end

  test "the same identity on another provider does not collide", c do
    other = insert_sandbox(user_id: c.sandbox.user_id, provider: "e2b", status: "starting")
    assert {:ok, first} = SandboxIdentity._unsafe_bind(c.sandbox, "provider-id")
    assert {:ok, second} = SandboxIdentity._unsafe_bind(other, "provider-id")
    assert first.provider != second.provider
    assert first.provider_instance_id == second.provider_instance_id
  end

  test "general sandbox attributes cannot set or replace the provider identity", c do
    assert {:ok, unchanged} =
             c.sandbox
             |> Sandbox.changeset(%{provider_instance_id: "worker-chosen"})
             |> Repo.update()

    assert unchanged.provider_instance_id == nil
    assert {:ok, bound} = SandboxIdentity._unsafe_bind(c.sandbox, "provider-issued")

    assert {:ok, unchanged} =
             bound
             |> Sandbox.changeset(%{"provider_instance_id" => "worker-chosen"})
             |> Repo.update()

    assert unchanged.provider_instance_id == "provider-issued"
  end

  test "a stale snapshot can repeat its binding but cannot replace it", c do
    assert {:ok, first} = SandboxIdentity._unsafe_bind(c.sandbox, "original")
    assert {:ok, again} = SandboxIdentity._unsafe_bind(c.sandbox, "original")
    assert first == again

    assert {:error, :provider_identity_changed} =
             SandboxIdentity._unsafe_bind(c.sandbox, "replacement")

    assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == "original"

    events =
      c.sandbox.user_id
      |> Fountain.Audit.list_recent_for_user(200)
      |> Enum.filter(&(&1.action == "sandbox.provider_identity_bound"))

    assert [event] = events
    assert event.resource_id == c.sandbox.id
    assert event.actor == "system:sandbox_identity"
    assert event.metadata == %{"provider" => "sprites"}
  end

  test "an identity remains reserved by its retired owning row", c do
    assert {:ok, bound} = SandboxIdentity._unsafe_bind(c.sandbox, "original")
    bound |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()
    other = insert_sandbox(user_id: insert_verified_user().id, status: "starting")

    assert {:error, changeset} = SandboxIdentity._unsafe_bind(other, "original")
    assert "has already been taken" in errors_on(changeset).provider
    assert Repo.get!(Sandbox, other.id).provider_instance_id == nil
    assert Repo.get!(Sandbox, bound.id).provider_instance_id == "original"
  end

  test "changed tenant, provider or name refuses a stale control response", c do
    for attrs <- [
          %{user_id: insert_verified_user().id},
          %{provider: "e2b"},
          %{sprite_name: "replacement"}
        ] do
      current = c.sandbox |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :ownership_changed} =
               SandboxIdentity._unsafe_bind(c.sandbox, "original")

      assert Repo.get!(Sandbox, current.id).provider_instance_id == nil

      current
      |> Ecto.Changeset.change(Map.take(c.sandbox, Map.keys(attrs)))
      |> Repo.update!()
    end
  end

  test "retirement during a provider lookup prevents late binding", c do
    expect(Managoat.Sandbox.Sprites, :get, fn handle ->
      c.sandbox |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()
      {:ok, %{raw: %{"name" => handle.name, "id" => "late"}}}
    end)

    assert {:error, :sandbox_retired} = SandboxIdentity._unsafe_capture(c.sandbox, c.handle)
    assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == nil
  end

  test "failed and deleted sandboxes cannot acquire a provider identity", c do
    c.sandbox |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
    assert {:error, :sandbox_retired} = SandboxIdentity._unsafe_bind(c.sandbox, "late")
    Repo.delete!(c.sandbox)
    assert {:error, :not_found} = SandboxIdentity._unsafe_bind(c.sandbox, "late")
  end

  test "a mismatched handle is refused before any provider request", c do
    reject(Managoat.Sandbox.Sprites, :get, 1)

    for handle <- [
          %{c.handle | name: "someone-else"},
          %{c.handle | provider: :e2b},
          %{c.handle | provider: "sprites"}
        ] do
      assert {:error, :ownership_changed} = SandboxIdentity._unsafe_capture(c.sandbox, handle)
    end
  end

  test "a response for a different name is refused", c do
    expect(Managoat.Sandbox.Sprites, :get, fn _ ->
      {:ok, %{raw: %{"name" => "someone-else", "id" => "other"}}}
    end)

    assert {:error, :ownership_changed} = SandboxIdentity._unsafe_capture(c.sandbox, c.handle)
    assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == nil
  end

  test "absent or malformed control identity never becomes a binding", c do
    for response <- [
          {:ok, %{status: :running}},
          {:ok, %{raw: %{"id" => "unscoped"}}},
          {:ok, %{raw: %{"name" => c.sandbox.sprite_name, "id" => nil}}},
          {:ok, %{raw: %{"name" => c.sandbox.sprite_name, "id" => ""}}},
          {:ok, %{raw: %{"name" => c.sandbox.sprite_name, "id" => String.duplicate("a", 257)}}}
        ] do
      stub(Managoat.Sandbox.Sprites, :get, fn _ -> response end)

      assert {:error, :provider_identity_missing} =
               SandboxIdentity._unsafe_capture(c.sandbox, c.handle)
    end

    assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == nil
  end

  test "provider uncertainty preserves the unbound row", c do
    expect(Managoat.Sandbox.Sprites, :get, fn _ -> {:error, :timeout} end)
    assert {:error, :timeout} = SandboxIdentity._unsafe_capture(c.sandbox, c.handle)
    assert Repo.get!(Sandbox, c.sandbox.id).provider_instance_id == nil
  end
end

defmodule Fountain.Conversations.SandboxIdentityLockTest do
  use Fountain.DataCase, async: false

  alias Fountain.Accounts.User
  alias Fountain.Conversations.{Sandbox, SandboxIdentity}

  for change <- [:identity, :owner] do
    @tag change: change
    test "binding rechecks #{change} after a PostgreSQL row-lock wait", %{change: change} do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = Repo.insert!(%User{email: "identity-#{Ecto.UUID.generate()}@example.test"})
        other = Repo.insert!(%User{email: "identity-#{Ecto.UUID.generate()}@example.test"})
        observed = insert_sandbox(user_id: user.id, status: "starting")
        owner = self()

        attrs =
          if change == :identity, do: [provider_instance_id: "first"], else: [user_id: other.id]

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              observed |> Ecto.Changeset.change(attrs) |> Repo.update!()
              send(owner, :row_locked)

              receive do
                :commit -> :ok
              after
                10_000 -> raise "identity row lock release timed out"
              end
            end)
          end)

        try do
          assert_receive :row_locked, 5_000
          waiting = independent(fn -> SandboxIdentity._unsafe_bind(observed, "second") end)

          try do
            waiting_pid = waiting.pid
            blocker_pid = blocker.pid
            assert_receive {:backend, ^blocker_pid, blocker_backend}, 5_000
            assert_receive {:backend, ^waiting_pid, waiting_backend}, 5_000
            refute waiting_backend == blocker_backend
            await_blocked(waiting_backend, System.monotonic_time(:millisecond) + 5_000)
            send(blocker.pid, :commit)
            assert {:ok, :ok} = Task.await(blocker)

            expected =
              if change == :identity, do: :provider_identity_changed, else: :ownership_changed

            assert {:error, ^expected} = Task.await(waiting)
            current = Repo.get!(Sandbox, observed.id)
            assert current.provider_instance_id == if(change == :identity, do: "first", else: nil)
            assert current.user_id == if(change == :owner, do: other.id, else: user.id)
          after
            Task.shutdown(waiting, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)

          Repo.delete_all(
            from e in Fountain.Audit.Event, where: e.user_id in ^[user.id, other.id]
          )

          Repo.delete!(Repo.get!(Sandbox, observed.id))
          Repo.delete!(user)
          Repo.delete!(other)
        end
      end)
    end
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no PostgreSQL row-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
