defmodule Fountain.Conversations.ConversationServerTurnMetricsTest do
  @moduledoc """
  Producer side of the turn-duration metric (#536).

  `FountainWeb.Telemetry` declares a histogram over
  `[:fountain, :turn, :completed]`; a metric subscribed to an event nobody
  emits scrapes empty forever and looks exactly like a healthy quiet system
  (#310). These pin that ConversationServer actually fires it, on every path
  that ends a turn, with the tags the histogram reads.
  """

  use Fountain.ConversationServerCase

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: env.id)
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, conv: conv}
  end

  # Forward turn-completed events to the test process for the duration of
  # one test. Handler ids are per-test so parallel modules can't collide —
  # these are async: false, but the handler table is global either way.
  defp capture_turn_completed do
    test_pid = self()
    handler_id = "turn-metrics-#{inspect(test_pid)}"

    :telemetry.attach(
      handler_id,
      [:fountain, :turn, :completed],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:turn_completed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_with_turn(conv) do
    stub_happy_sprite()
    ref = make_ref()

    Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts ->
      {:ok, %{ref: ref, pid: self()}}
    end)

    Mimic.stub(Sprites, :write, fn _cmd, _data -> :ok end)
    Mimic.stub(Sprites, :close_stdin, fn _cmd -> :ok end)

    {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")
    {pid, ref}
  end

  describe "[:fountain, :turn, :completed]" do
    test "a clean exit emits a duration tagged runtime + completed", %{conv: conv} do
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, measurements, metadata}
      assert metadata.runtime == "claude"
      assert metadata.status == "completed"

      # Metadata, never a tag: it's what makes the JSON log line point at a
      # conversation, and as a label it would mint a series per conversation.
      assert metadata.conv_id == conv.id

      # Milliseconds, not native units or seconds: the histogram's buckets
      # are in ms and a unit mix-up puts every turn in the first or last one.
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert measurements.duration_ms < 60_000

      GenServer.stop(pid)
    end

    test "a non-zero exit emits with status failed", %{conv: conv} do
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, _measurements, %{status: "failed"}}

      GenServer.stop(pid)
    end

    test "a dropped sprite socket mid-turn still emits (#413)", %{conv: conv} do
      # This path fails the turn without an :exit ever arriving. Left out, a
      # runtime whose sockets drop would look like it had no slow turns at
      # all — the histogram would simply lose those samples.
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, _measurements, %{status: "failed"}}

      GenServer.stop(pid)
    end

    test "an interrupt emits with status interrupted", %{conv: conv} do
      capture_turn_completed()
      {pid, _ref} = start_with_turn(conv)

      assert :ok = GenServer.call(pid, :interrupt)

      assert_received {:turn_completed, _measurements, %{status: "interrupted"}}

      GenServer.stop(pid)
    end

    test "a spawn that never starts emits nothing", %{conv: conv} do
      # There is no run to time — the turn is marked failed before any
      # command exists. A sample here would be a few milliseconds of "turn
      # duration" dragging the histogram's low end down.
      capture_turn_completed()
      stub_happy_sprite()
      Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts -> {:error, :econnrefused} end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      refute_received {:turn_completed, _, _}

      GenServer.stop(pid)
    end

    test "one turn emits exactly one sample", %{conv: conv} do
      # The stamp is cleared on the terminal path. If it were not, a stale
      # one would attach to the next turn and report a duration spanning
      # both.
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, _, _}
      refute_received {:turn_completed, _, _}

      GenServer.stop(pid)
    end
  end
end
