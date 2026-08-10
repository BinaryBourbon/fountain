defmodule Fountain.Conversations.CheckpointTest do
  @moduledoc """
  Checkpoint id resolution, against the shapes the Sprites library really
  returns.

  #652 survived because nothing was ever written against those shapes: the old
  extractor matched maps with `checkpoint_id`/`id` keys, the library yields
  `%Sprites.StreamMessage{}` structs carrying the id as prose, and the only
  mention of `create_checkpoint` in the whole suite was a permissive stub. So
  every fixture here is a real struct, copied from a live run.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.Provisioning

  setup :set_mimic_global

  # Verbatim from a live sprite (2026-08-10). The id appears only inside `data`.
  defp create_stream do
    [
      %Sprites.StreamMessage{type: "info", data: "Creating checkpoint...", error: nil},
      %Sprites.StreamMessage{type: "info", data: "Checkpoint created successfully", error: nil},
      %Sprites.StreamMessage{type: "info", data: "\nCheckpoint Details:", error: nil},
      %Sprites.StreamMessage{type: "info", data: "  ID: v1", error: nil},
      %Sprites.StreamMessage{type: "info", data: "  Created: 2026-08-10 19:42:00", error: nil},
      %Sprites.StreamMessage{type: "info", data: "  Path: checkpoints/v1", error: nil},
      %Sprites.StreamMessage{
        type: "complete",
        data: "Checkpoint v1 created successfully",
        error: nil
      }
    ]
  end

  defp checkpoint(id, comment, time) do
    %Sprites.Checkpoint{id: id, comment: comment, create_time: time, history: []}
  end

  defp stub_sprites(checkpoints) do
    Mimic.stub(Sprites, :create_checkpoint, fn _sprite, _opts -> {:ok, create_stream()} end)
    Mimic.stub(Sprites, :list_checkpoints, fn _sprite -> {:ok, checkpoints} end)
  end

  defp env_with_name(name) do
    user = insert_verified_user()
    insert_env(user_id: user.id, name: name)
  end

  describe "create_checkpoint/2" do
    test "records the id the sprite actually saved" do
      env = env_with_name("proj")

      stub_sprites([
        checkpoint("Current", nil, ~U[2026-08-10 19:42:35Z]),
        checkpoint("v1", "aod env proj", ~U[2026-08-10 19:42:00Z])
      ])

      assert {:ok, "v1"} = Provisioning.create_checkpoint(%{name: "s"}, env)
      assert Fountain.Environments._unsafe_get_environment!(env.id).checkpoint_id == "v1"
    end

    test "never picks the synthetic Current entry" do
      # `Current` is the live filesystem, not a saved checkpoint, and it is
      # always the newest thing in the list — so a plain max_by picks it and
      # writes an id that restores nothing.
      env = env_with_name("proj")

      stub_sprites([
        checkpoint("Current", nil, ~U[2026-08-10 20:00:00Z]),
        checkpoint("v3", "aod env proj", ~U[2026-08-10 19:00:00Z])
      ])

      assert {:ok, "v3"} = Provisioning.create_checkpoint(%{name: "s"}, env)
    end

    test "prefers this environment's own checkpoint over a newer stranger" do
      env = env_with_name("proj")

      stub_sprites([
        checkpoint("v9", "someone else", ~U[2026-08-10 23:00:00Z]),
        checkpoint("v2", "aod env proj", ~U[2026-08-10 19:00:00Z])
      ])

      assert {:ok, "v2"} = Provisioning.create_checkpoint(%{name: "s"}, env)
    end

    test "falls back to the newest saved checkpoint when no comment matches" do
      env = env_with_name("proj")

      stub_sprites([
        checkpoint("v1", nil, ~U[2026-08-10 19:00:00Z]),
        checkpoint("v2", nil, ~U[2026-08-10 20:00:00Z])
      ])

      assert {:ok, "v2"} = Provisioning.create_checkpoint(%{name: "s"}, env)
    end

    test "reports no_checkpoint_id rather than writing a bogus one" do
      env = env_with_name("proj")
      stub_sprites([checkpoint("Current", nil, ~U[2026-08-10 20:00:00Z])])

      assert {:error, :no_checkpoint_id} = Provisioning.create_checkpoint(%{name: "s"}, env)
      assert is_nil(Fountain.Environments._unsafe_get_environment!(env.id).checkpoint_id)
    end

    test "the creation stream is drained before the list is read" do
      # The checkpoint is not on the server until the stream completes, so
      # listing first races the upload and finds only `Current`.
      env = env_with_name("proj")
      test = self()

      Mimic.stub(Sprites, :create_checkpoint, fn _sprite, _opts ->
        {:ok, Stream.map(create_stream(), fn msg -> send(test, :drained) && msg end)}
      end)

      Mimic.stub(Sprites, :list_checkpoints, fn _sprite ->
        send(test, :listed)
        {:ok, [checkpoint("v1", "aod env proj", ~U[2026-08-10 19:42:00Z])]}
      end)

      assert {:ok, "v1"} = Provisioning.create_checkpoint(%{name: "s"}, env)

      assert_received :drained
      assert_received :listed
    end

    test "a list failure is a logged miss, not a crash" do
      env = env_with_name("proj")
      Mimic.stub(Sprites, :create_checkpoint, fn _s, _o -> {:ok, create_stream()} end)
      Mimic.stub(Sprites, :list_checkpoints, fn _s -> {:error, :nope} end)

      assert {:error, :no_checkpoint_id} = Provisioning.create_checkpoint(%{name: "s"}, env)
    end

    test "no environment is not an error worth retrying" do
      assert {:error, :no_env} = Provisioning.create_checkpoint(%{name: "s"}, nil)
    end
  end
end
