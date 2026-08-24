defmodule Fountain.Conversations.HomeCheckpointTest do
  @moduledoc """
  A persistent home is checkpointed when it parks, where the provider can
  (ADR 0023, #1073). The checkpoint is best-effort and machine-scoped: it is
  recorded on the row and on every live transcript, and a failure never
  blocks the park.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.Conversations.{HomeCheckpoint, LogEvent}
  alias Fountain.Repo

  defp home(user, overrides \\ %{}) do
    insert_sandbox(
      Map.merge(
        %{user_id: user.id, status: "ready", mode: "persistent", provider: "sprites"},
        overrides
      )
    )
  end

  defp stages(conv_id) do
    Repo.all(
      from e in LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == "checkpoint",
        select: {e.state, e.data}
    )
  end

  describe "on_park/1" do
    test "records the checkpoint on the row and on every live transcript" do
      user = insert_verified_user()
      sandbox = home(user)
      a = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      b = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      gone = insert_conversation(user_id: user.id, sandbox: sandbox, status: "terminated")

      stub(Fountain.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)

      stub(Fountain.Sandbox, :create_checkpoint, fn handle, opts ->
        assert handle.name == sandbox.sprite_name
        assert opts[:comment] == "home park #{sandbox.id}"
        {:ok, "v7"}
      end)

      assert {:ok, "v7"} = HomeCheckpoint.on_park(sandbox)

      reloaded = Repo.reload(sandbox)
      assert reloaded.provider_meta["checkpoint_id"] == "v7"
      assert {:ok, _, _} = DateTime.from_iso8601(reloaded.provider_meta["checkpoint_at"])
      assert %{id: "v7", at: at} = HomeCheckpoint.recorded(reloaded)
      assert at == reloaded.provider_meta["checkpoint_at"]

      for conv <- [a, b] do
        assert [{"done", data}] = stages(conv.id)
        assert Jason.decode!(data)["checkpoint_id"] == "v7"
      end

      assert stages(gone.id) == []
    end

    test "keeps the rest of provider_meta" do
      user = insert_verified_user()
      sandbox = home(user, %{provider_meta: %{"public_url" => "https://x.example"}})
      stub(Fountain.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)
      stub(Fountain.Sandbox, :create_checkpoint, fn _handle, _opts -> {:ok, "v1"} end)

      assert {:ok, "v1"} = HomeCheckpoint.on_park(sandbox)
      assert Repo.reload(sandbox).provider_meta["public_url"] == "https://x.example"
    end

    test "an ephemeral sandbox is never checkpointed" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready", mode: "ephemeral")
      stub(Fountain.Sandbox, :supports?, fn _provider, :checkpoint -> true end)
      reject(&Fountain.Sandbox.create_checkpoint/2)

      assert :skipped = HomeCheckpoint.on_park(sandbox)
      assert Repo.reload(sandbox).provider_meta == %{}
    end

    test "a provider without checkpoints is skipped" do
      user = insert_verified_user()
      sandbox = home(user, %{provider: "e2b"})
      stub(Fountain.Sandbox, :supports?, fn :e2b, :checkpoint -> false end)
      reject(&Fountain.Sandbox.create_checkpoint/2)

      assert :skipped = HomeCheckpoint.on_park(sandbox)
    end

    test "a failed checkpoint is recorded as a failed stage and does not touch the row" do
      user = insert_verified_user()
      sandbox = home(user)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      stub(Fountain.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)

      stub(Fountain.Sandbox, :create_checkpoint, fn _handle, _opts ->
        {:error, {:invalid, "checkpoints disabled for this sprite"}}
      end)

      assert {:error, {:invalid, _}} = HomeCheckpoint.on_park(sandbox)
      assert Repo.reload(sandbox).provider_meta == %{}
      assert [{"failed", data}] = stages(conv.id)
      assert Jason.decode!(data)["reason"] =~ "checkpoints disabled"
    end
  end

  describe "recorded/1" do
    test "is nil until a park has recorded one" do
      # Two users: a user has one home per identity (the partial unique
      # index), and both of these have the empty identity.
      assert HomeCheckpoint.recorded(home(insert_verified_user())) == nil

      with_url = home(insert_verified_user(), %{provider_meta: %{"public_url" => "u"}})
      assert HomeCheckpoint.recorded(with_url) == nil
    end
  end
end
