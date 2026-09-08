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
