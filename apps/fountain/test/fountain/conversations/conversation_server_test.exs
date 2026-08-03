defmodule Fountain.Conversations.ConversationServerTest do
  @moduledoc """
  First tests for `ConversationServer`.

  1,183 lines that provision sandboxes, hold decrypted tenant secrets, mint API
  keys and spend money on sprites — with no test file at all since launch, and
  excluded from the coverage gate on top of that. Every caller `Mimic.copy`'d it
  away, so the module was verified only by running the product.

  These cover the lifecycle: provisioning succeeds and the sandbox reaches
  `ready`; each way provisioning can fail leaves the sandbox and conversation
  marked `failed` rather than stuck; teardown revokes the sprite's callback key;
  and a terminate against a dead server still cleans up the rows.
  """

  use Fountain.ConversationServerCase

  alias Fountain.Accounts
  alias Fountain.Repo

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

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  describe "provisioning — happy path" do
    test "drives the sandbox to ready", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end

    test "asks the runtime to write its config and prepare the sprite", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert_received :write_config
      assert_received :prepare_sprite
      GenServer.stop(pid)
    end

    test "mints a sprite-scoped callback key and records it on the conversation", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      reloaded = Conversations._unsafe_get_conversation!(conv.id)
      assert reloaded.callback_api_key_id

      key = Repo.get(Accounts.ApiKey, reloaded.callback_api_key_id)
      assert key.scopes == ["sprite"]
      assert key.expires_at
      refute key.revoked_at

      GenServer.stop(pid)
    end

    test "runs the first turn when a prompt is supplied", %{conv: conv} do
      stub_happy_sprite()
      # The server reads command.ref, so the spawn result must be a command struct
      # rather than a bare pid.
      Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts ->
        {:ok, %{ref: make_ref(), pid: self()}}
      end)

      Mimic.stub(Sprites, :write, fn _cmd, _data -> :ok end)
      Mimic.stub(Sprites, :close_stdin, fn _cmd -> :ok end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello there")

      assert_received {:build_command, "hello there", _mode, _session, _opts}
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.prompt == "hello there"

      GenServer.stop(pid)
    end

    test "does not start a turn without a prompt", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert Conversations._unsafe_list_turns(conv.id) == []
      GenServer.stop(pid)
    end

    test "the prompt reaches a server the Horde registry cannot resolve", %{conv: conv} do
      # The #367 regression: queue_initial_prompt used to cast through the
      # Horde registry, and Horde's CRDT registrations propagate
      # asynchronously — a cast fired right after start_child could hit an
      # unresolved via-name and vanish. The server provisioned, the user's
      # first prompt was silently gone. Delivery now targets the pid, which
      # this harness proves by construction: its servers run outside Horde,
      # so the registry genuinely cannot resolve them.
      stub_happy_sprite()

      Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts ->
        {:ok, %{ref: make_ref(), pid: self()}}
      end)

      Mimic.stub(Sprites, :write, fn _cmd, _data -> :ok end)
      Mimic.stub(Sprites, :close_stdin, fn _cmd -> :ok end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "first prompt")

      # Guards the premise, not the fix: the harness must keep its servers
      # out of Horde, or the turn assertion below stops demonstrating
      # anything about registry-independent delivery. It can only fail if
      # the harness changes (#406 item 11).
      assert Horde.Registry.lookup(Fountain.ConversationRegistry, conv.id) == []
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.prompt == "first prompt"

      GenServer.stop(pid)
    end
  end

  describe "provisioning — tenant isolation" do
    test "a cross-tenant environment_id on the agent is not materialised" do
      attacker = insert_verified_user()
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id, checkpoint_id: "cp_victim")

      # A legacy row from before create_agent validated environment ownership,
      # inserted through the bare changeset the context no longer exposes to
      # cross-tenant ids. The server must refuse to load it.
      {:ok, agent} =
        %Fountain.Agents.Agent{}
        |> Fountain.Agents.Agent.changeset(%{
          "name" => "legacy-cross-tenant",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude",
          "user_id" => attacker.id,
          "environment_id" => victim_env.id
        })
        |> Repo.insert()

      sandbox = insert_sandbox(user_id: attacker.id, status: "pending")

      conv =
        insert_conversation(
          user_id: attacker.id,
          agent: agent,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :restore_checkpoint, fn _s, id ->
        send(test_pid, {:restore_checkpoint, id})
        {:ok, :restored}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {pid, _ref, :alive} = start_server(conv)

          # The victim's checkpoint must never be restored into the
          # attacker's sprite; the conversation still provisions, just
          # without the foreign environment.
          refute_received {:restore_checkpoint, _}
          assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
          GenServer.stop(pid)
        end)

      assert log =~ "not owned by user #{attacker.id}"
    end
  end

  describe "stage metrics — the producer end of #310" do
    # These drive the real server and read the Prometheus scrape before and
    # after. The reporter is node-global and cumulative and other tests in
    # this file emit the very same events, so "a sample exists" is satisfied
    # before these tests even run (#406) — only the delta across this test's
    # own action is evidence the action emitted.
    defp scrape_body do
      # The reporter aggregates synchronously on the telemetry event, but give
      # the handler a moment before scraping.
      Process.sleep(50)
      conn = FountainWeb.MetricsPlug.call(Plug.Test.conn(:get, "/metrics"), [])
      assert conn.status == 200
      conn.resp_body
    end

    # Current value of the {stage, status} counter series, 0 when absent.
    # stage and status are the metric's only tags, so at most one line matches.
    defp stage_count(body, stage, status) do
      body
      |> String.split("\n")
      |> Enum.find_value(0, fn line ->
        if String.starts_with?(line, "fountain_stage_count{") and
             line =~ ~s(stage="#{stage}") and line =~ ~s(status="#{status}") do
          {value, ""} = line |> String.split(" ") |> List.last() |> Integer.parse()
          value
        end
      end)
    end

    # Total observations recorded by a histogram (its _count line), 0 when absent.
    defp histogram_count(body, prefix) do
      body
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.starts_with?(line, prefix) and line =~ "_count"
      end)
      |> Enum.map(fn line ->
        {value, ""} = line |> String.split(" ") |> List.last() |> Integer.parse()
        value
      end)
      |> Enum.sum()
    end

    test "a successful provision lands in the scrape as provision/done", %{conv: conv} do
      stub_happy_sprite()
      before_body = scrape_body()

      {pid, _ref, :alive} = start_server(conv)
      GenServer.stop(pid)

      after_body = scrape_body()

      # Exactly this provision — and a *successful* one: done moved, failed
      # did not.
      assert stage_count(after_body, "provision", "done") ==
               stage_count(before_body, "provision", "done") + 1

      assert stage_count(after_body, "provision", "failed") ==
               stage_count(before_body, "provision", "failed")

      # The span around fresh provisioning feeds the duration histogram.
      assert histogram_count(after_body, "fountain_fresh_provision_stop_duration") ==
               histogram_count(before_body, "fountain_fresh_provision_stop_duration") + 1
    end

    test "a failed provision lands in the scrape as provision/failed", %{conv: conv} do
      stub_happy_sprite()
      Mimic.stub(Sprites, :create, fn _client, _name -> {:error, :quota_exceeded} end)
      before_body = scrape_body()

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      after_body = scrape_body()

      assert stage_count(after_body, "provision", "failed") ==
               stage_count(before_body, "provision", "failed") + 1

      assert stage_count(after_body, "provision", "done") ==
               stage_count(before_body, "provision", "done")
    end

    test "a completed turn lands in the scrape as turn/done", %{conv: conv} do
      stub_happy_sprite()
      cmd_ref = make_ref()

      Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts ->
        {:ok, %{ref: cmd_ref, pid: self()}}
      end)

      Mimic.stub(Sprites, :write, fn _cmd, _data -> :ok end)
      Mimic.stub(Sprites, :close_stdin, fn _cmd -> :ok end)

      before_body = scrape_body()

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "count me")
      send(pid, {:exit, %{ref: cmd_ref}, 0})
      _ = :sys.get_state(pid)
      GenServer.stop(pid)

      after_body = scrape_body()

      assert stage_count(after_body, "turn", "done") ==
               stage_count(before_body, "turn", "done") + 1
    end
  end

  describe "provisioning — failure paths" do
    test "a sprite that cannot be created marks both rows failed", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()
      Mimic.stub(Sprites, :create, fn _client, _name -> {:error, :quota_exceeded} end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a failing provisioning step destroys the sprite rather than leaking it", %{conv: conv} do
      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        {:error, :apt_failed}
      end)

      Mimic.stub(Sprites, :destroy, fn sprite ->
        send(test_pid, {:destroyed, sprite.name})
        :ok
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      # The sprite is billed until it is destroyed, so a failed provision that
      # leaves it running costs money indefinitely.
      assert_received {:destroyed, "test-sprite"}
    end

    test "a runtime that fails to prepare marks the sandbox failed", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()

      {_pid, ref, _} = start_server(conv, runtime: Fountain.Test.FailingRuntime)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end

    test "an unexpected exception is caught and does not leave the sandbox pending", %{
      conv: conv,
      sandbox: sandbox
    } do
      # The provision path wraps itself in a rescue precisely so a bug in any
      # step cannot strand a conversation in `pending` forever.
      stub_happy_sprite()

      Mimic.stub(Fountain.SpriteSkills, :mount, fn _s, _r, _sk ->
        raise "boom"
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "unreadable tenant credentials fail the conversation rather than provisioning blind", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:error, :unwrap_failed} end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "turn lifecycle on a running server" do
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

    test "a completed command closes the turn and returns the conversation to idle", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      assert turn.exit_code == 0
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a non-zero exit marks the turn failed but keeps the conversation usable", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert turn.exit_code == 1

      # A failed turn is not a failed conversation — the user can prompt again.
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a spawn that never starts returns the conversation to idle", %{conv: conv} do
      # The conversation is set to "running" just before the spawn attempt.
      # Before this reset, a failed spawn marked the turn failed but left the
      # conversation reporting "running" in the API and UI indefinitely.
      stub_happy_sprite()
      Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts -> {:error, :econnrefused} end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "stdout is persisted as log events", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:stdout, %{ref: ref}, "hello from the sprite"})
      _ = :sys.get_state(pid)

      events = Conversations._unsafe_list_log_events(conv.id)
      assert Enum.any?(events, &(&1.data =~ "hello from the sprite"))

      GenServer.stop(pid)
    end

    test "a dropped sprite WebSocket fails the turn and frees the conversation (#413)", %{
      conv: conv
    } do
      # Sprites.Command sends {:error, %{ref: ...}, reason} when the socket
      # drops mid-run, then stops. Pre-#413 the handler logged and kept
      # current_command set, so the turn stayed "running" forever, every
      # prompt got {:error, :busy}, and both reclaim paths were suppressed —
      # the sprite billed until max_lifetime.
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # The recovery the user actually needs: prompting again works.
      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2

      GenServer.stop(pid)
    end

    test "an error for a stale command ref does not touch the current turn", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: make_ref()}, :closed})
      _ = :sys.get_state(pid)

      # Still mid-turn: the running turn is untouched and busy is still busy.
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "running"
      assert {:error, :busy} = GenServer.call(pid, {:send_prompt, "second", []})

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)
      GenServer.stop(pid)
    end

    test "prompting while a turn is running is refused rather than queued", %{conv: conv} do
      {pid, _ref} = start_with_turn(conv)

      # There is no queue, so a second prompt mid-turn must be rejected rather
      # than silently dropped or interleaved.
      assert {:error, :busy} = GenServer.call(pid, {:send_prompt, "second", []})

      GenServer.stop(pid)
    end

    test "a prompt after the turn finishes starts a new turn", %{conv: conv} do
      {pid, ref} = start_with_turn(conv)
      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert :ok = GenServer.call(pid, {:send_prompt, "second", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2

      GenServer.stop(pid)
    end

    test "interrupt with nothing running reports idle rather than pretending to act", %{
      conv: conv
    } do
      stub_happy_sprite()
      {pid, _mon, :alive} = start_server(conv)

      assert {:error, :idle} = GenServer.call(pid, :interrupt)
      GenServer.stop(pid)
    end
  end

  describe "secret redaction wiring" do
    test "the server registers the sprite env for redaction", %{conv: conv, env: env} do
      # The registry only protects anything if something populates it. This is
      # the assertion that would have caught Billing.emit/5 having no call
      # sites: verify from the operation, not from the helper.
      {:ok, _} =
        Fountain.Environments.upsert_secret(
          env,
          %{"key" => "LEAKY_TOKEN", "value" => "tenant-secret-cccccccccccc"},
          <<0::256>>
        )

      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:ok, <<0::256>>} end)

      {pid, _ref, :alive} = start_server(conv)

      values = Fountain.Conversations.Redaction.lookup(conv.id)
      assert "tenant-secret-cccccccccccc" in values

      GenServer.stop(pid)
    end

    test "registered values are forgotten when the server stops", %{conv: conv} do
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      GenServer.stop(pid)
      assert_stopped(ref)

      assert Fountain.Conversations.Redaction.lookup(conv.id) == []
    end
  end

  describe "teardown" do
    test "revokes the sprite's callback key when the server stops", %{conv: conv} do
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      key_id = Conversations._unsafe_get_conversation!(conv.id).callback_api_key_id
      refute Repo.get(Accounts.ApiKey, key_id).revoked_at

      GenServer.stop(pid)
      assert_stopped(ref)

      # Otherwise the sandbox's credential outlives the sandbox.
      assert Repo.get(Accounts.ApiKey, key_id).revoked_at
    end
  end

  describe "terminate/1 with no running server" do
    test "still marks the conversation and sandbox terminated", %{conv: conv, sandbox: sandbox} do
      # After a BEAM restart the GenServer is gone but the rows remain, and a
      # user still needs to be able to clean up.
      assert :ok = ConversationServer.terminate(conv.id)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "terminated"
    end

    test "reports not_running for an unknown conversation" do
      assert {:error, :not_running} = ConversationServer.terminate(Ecto.UUID.generate())
    end

    test "does not resurrect an already-failed sandbox", %{conv: conv, sandbox: sandbox} do
      {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

      assert :ok = ConversationServer.terminate(conv.id)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "interrupt/1 and send_prompt/3 with no running server" do
    test "interrupt reports not_running", %{conv: conv} do
      assert {:error, :not_running} = ConversationServer.interrupt(conv.id)
    end

    test "send_prompt for an unknown conversation reports not_running" do
      assert {:error, :not_running} =
               ConversationServer.send_prompt(Ecto.UUID.generate(), "hi", [])
    end

    test "send_prompt to a terminated conversation reports gone", %{conv: conv} do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      assert {:error, :gone} = ConversationServer.send_prompt(conv.id, "hi", [])
    end
  end
end
