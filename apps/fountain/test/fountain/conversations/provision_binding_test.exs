defmodule Fountain.Conversations.ProvisionBindingTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.ProvisionBinding

  test "a replayed child accepts its committed destination without needing another wake" do
    user = insert_verified_user()
    source = insert_sandbox(user_id: user.id, status: "terminated")
    destination = insert_sandbox(user_id: user.id, status: "ready")
    parent = insert_conversation(user_id: user.id, sandbox: destination)
    assert :ok = ProvisionBinding._unsafe_await(parent.id, destination.id, source.id)
  end

  test "a different winning binding is refused without changing it" do
    user = insert_verified_user()
    source = insert_sandbox(user_id: user.id, status: "terminated")
    destination = insert_sandbox(user_id: user.id)
    winner = insert_sandbox(user_id: user.id, status: "ready")
    parent = insert_conversation(user_id: user.id, sandbox: winner)

    assert {:error, :ownership_changed} =
             ProvisionBinding._unsafe_await(parent.id, destination.id, source.id)

    assert Repo.reload!(parent).sandbox_id == winner.id
    assert Repo.reload!(destination).status == "pending"
  end

  test "foreign and deleted destinations cannot authorize provisioning" do
    parent = insert_conversation()
    foreign = insert_sandbox()

    assert {:error, :ownership_changed} =
             ProvisionBinding._unsafe_await(parent.id, foreign.id, parent.sandbox_id)

    assert {:error, :ownership_changed} =
             ProvisionBinding._unsafe_await(parent.id, Ecto.UUID.generate(), parent.sandbox_id)
  end

  test "a failed handoff times out without retiring or rebinding a machine" do
    user = insert_verified_user()
    source = insert_sandbox(user_id: user.id, status: "terminated")
    destination = insert_sandbox(user_id: user.id)
    parent = insert_conversation(user_id: user.id, sandbox: source)

    assert {:error, :binding_timeout} =
             ProvisionBinding._unsafe_await(parent.id, destination.id, source.id)

    assert Repo.reload!(parent).sandbox_id == source.id
    assert Repo.reload!(source).status == "terminated"
    assert Repo.reload!(destination).status == "pending"
  end
end
