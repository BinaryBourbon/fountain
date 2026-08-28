defmodule Fountain.Workers.AutonomousTurnReaperTest do
  @moduledoc """
  #1197: a turn stuck `running` with no live `ConversationServer` behind
  it never closes on its own. As with `SandboxReaper`, the risk here is
  asymmetric — failing to reap costs a stuck `presence: working`, while
  reaping a turn a server is still actively driving corrupts state out
  from under it — so most of these tests are about what the sweep leaves
  alone.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Repo
  alias Fountain.Workers.AutonomousTurnReaper

  setup :set_mimic_global

  defp minutes_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 60, :second) |> DateTime.truncate(:second)

  defp stub_no_live_servers do
    stub(Fountain.Conversations.ConversationServer, :whereis, fn _id -> nil end)
  end

  describe "sweep_stuck_turns/0" do
    test "a turn running past the deadline with no live server is closed" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

      turn =
        insert_turn(conv, %{
          status: "running",
          origin: "autonomous",
          started_at: minutes_ago(45)
        })

      stub_no_live_servers()

      capture_log(fn -> assert 1 = AutonomousTurnReaper.sweep_stuck_turns() end)

      reloaded = Repo.reload(turn)
      assert reloaded.status == "interrupted"
      assert %DateTime{} = reloaded.ended_at

      # The orphaned turn was the only thing keeping the conversation
      # `running` — same outcome `Conversations.orphan_turn/2` gives
      # `ConversationServer`'s own reattach path.
      assert Repo.reload(conv).status == "idle"
    end

    test "a turn with a live ConversationServer is left alone, however old" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

      turn =
        insert_turn(conv, %{
          status: "running",
          origin: "autonomous",
          started_at: minutes_ago(600)
        })

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      assert 0 = AutonomousTurnReaper.sweep_stuck_turns()
      assert Repo.reload(turn).status == "running"
    end

    test "a recent running turn is left alone" do
      # Still legitimately working, not stuck — the sweep's deadline is
      # deliberately wider than the in-process autonomous_quiet watchdog.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

      turn =
        insert_turn(conv, %{
          status: "running",
          origin: "autonomous",
          started_at: minutes_ago(5)
        })

      stub_no_live_servers()

      assert 0 = AutonomousTurnReaper.sweep_stuck_turns()
      assert Repo.reload(turn).status == "running"
    end

    test "completed, failed, and interrupted turns are never touched" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")

      for status <- ["completed", "failed", "interrupted", "pending"] do
        insert_turn(conv, %{status: status, started_at: minutes_ago(600)})
      end

      stub_no_live_servers()

      assert 0 = AutonomousTurnReaper.sweep_stuck_turns()
    end

    test "a user-originated turn stuck running is closed too" do
      # mark_orphan/orphan_turn never distinguished origin — a stuck
      # `user` turn strands a human's conversation exactly like a stuck
      # `autonomous` one, and #1197's fix is the same either way.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

      turn =
        insert_turn(conv, %{
          status: "running",
          origin: "user",
          started_at: minutes_ago(45)
        })

      stub_no_live_servers()

      assert 1 = AutonomousTurnReaper.sweep_stuck_turns()
      assert Repo.reload(turn).status == "interrupted"
    end

    test "publishes the same reattach/interrupted stage event the reattach path uses" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")

      turn =
        insert_turn(conv, %{
          status: "running",
          origin: "autonomous",
          started_at: minutes_ago(45)
        })

      stub_no_live_servers()

      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

      assert 1 = AutonomousTurnReaper.sweep_stuck_turns()

      assert_receive {:log_event, %{stage: "reattach", state: "interrupted"} = event}
      data = Jason.decode!(event.data)
      assert data["outcome"] == "turn_orphaned"
      assert data["turn_id"] == turn.id
      assert data["reason"] == "stuck_running_no_server"
    end
  end

  describe "Conversations.orphan_turn/2" do
    # The shared function both terminate/2 and this worker call — tested
    # directly here since there is no dedicated conversations_test.exs in
    # this checkout to house it.
    test "closes the turn and flips the conversation back to idle" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
      turn = insert_turn(conv, %{status: "running", origin: "autonomous"})

      assert :ok = Conversations.orphan_turn(turn, "test_reason")

      assert Repo.reload(turn).status == "interrupted"
      assert Repo.reload(conv).status == "idle"
    end
  end
end
