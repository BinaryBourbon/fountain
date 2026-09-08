defmodule Fountain.Conversations.SandboxAdmissionFenceTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.Turn

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready", mode: "persistent")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{sandbox: sandbox, conv: conv}
  end

  for status <- ~w(pending starting suspended terminated failed) do
    @status status
    test "a #{@status} machine cannot admit user or autonomous work", c do
      c.sandbox |> Ecto.Changeset.change(status: @status) |> Repo.update!()
      attrs = turn_attrs(c.conv)

      assert {:error, :sandbox_not_ready} =
               Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)

      assert {:error, :sandbox_not_ready} =
               Conversations._unsafe_create_autonomous_turn(attrs, c.sandbox.id)

      assert Repo.aggregate(Turn, :count) == 0
      assert Repo.reload!(c.conv).status == "idle"
    end
  end

  test "ready owned machines still admit both sources of work", c do
    assert {:ok, first} =
             Conversations._unsafe_create_turn_on_sandbox(
               turn_attrs(c.conv),
               c.sandbox.id,
               :unbounded
             )

    first |> Ecto.Changeset.change(status: "completed") |> Repo.update!()

    assert {:ok, second} =
             Conversations._unsafe_create_autonomous_turn(
               %{turn_attrs(c.conv) | turn_number: 2},
               c.sandbox.id
             )

    assert second.status == "running"
    assert Repo.reload!(c.conv).status == "running"
  end

  test "a ready machine belonging to another tenant cannot receive either turn source", c do
    c.sandbox |> Ecto.Changeset.change(user_id: insert_verified_user().id) |> Repo.update!()
    attrs = turn_attrs(c.conv)

    assert {:error, :ownership_changed} =
             Conversations._unsafe_create_turn_on_sandbox(attrs, c.sandbox.id, :unbounded)

    assert {:error, :ownership_changed} =
             Conversations._unsafe_create_autonomous_turn(attrs, c.sandbox.id)

    assert Repo.aggregate(Turn, :count) == 0
  end

  defp turn_attrs(conv) do
    %{
      conversation_id: conv.id,
      turn_number: 1,
      prompt: "start work",
      status: "running",
      started_at: DateTime.utc_now()
    }
  end
end
