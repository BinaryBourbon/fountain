defmodule Fountain.ConversationsWakeTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations

  # wake_conversation/2 — resume, provider stickiness and the sandbox it lands on.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # wake_conversation/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "wake_conversation/2" do
    test "returns {:error, :not_found} when conversation does not exist" do
      assert {:error, :not_found} = Conversations.wake_conversation(Ecto.UUID.generate())
    end

    test "returns {:error, :gone} when conversation status is terminated" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "terminated")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:error, :gone} when conversation status is failed" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "failed")

      assert {:error, :gone} = Conversations.wake_conversation(conv.id)
    end

    test "an idle conversation whose sandbox was reclaimed is still resumable" do
      # The case #167 created and the reason `completed` was never needed:
      # reclaiming an idle sandbox leaves the conversation resumable rather
      # than closing it, so waking it must not be refused as :gone.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "terminated")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      refute match?({:error, :gone}, Conversations.wake_conversation(conv.id))
    end

    test "returns {:error, :no_agent} when conversation has no agent_id" do
      user = insert_verified_user()
      # insert_conversation does not set an agent by default, so agent_id is nil
      conv = insert_conversation(user_id: user.id, status: "idle")

      assert {:error, :no_agent} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} reusing existing sandbox when sprite is still alive" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-alive")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      fake_client = %{}

      stub(Fountain.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: "test-sprite-alive"}}}
      end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "a reuse that loses the start race hands the prompt to the winner (#667)" do
      # Two concurrent wakes of the same suspended/ready sandbox: the loser
      # used to get the raw {:error, {:already_started, pid}} back from
      # start_conversation_server, so the prompt was silently dropped instead
      # of reaching the winner's server.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-race")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      winner = spawn(fn -> Process.sleep(:infinity) end)
      test_pid = self()

      stub(Fountain.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: "test-sprite-race"}}}
      end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:error, {:already_started, winner}}
      end)

      stub(Fountain.Conversations.ConversationServer, :queue_initial_prompt, fn pid, prompt ->
        send(test_pid, {:queued, pid, prompt})
        :ok
      end)

      assert {:ok, woken} = Conversations.wake_conversation(conv.id, "hello")
      assert_receive {:queued, ^winner, "hello"}

      # Reuse touches no row — the conversation still names the sandbox it
      # started with.
      assert woken.sandbox_id == sandbox.id
    end

    test "waking a suspended sandbox flips it to ready and stamps the clock" do
      # The core of decisions/0017: the parked sprite is reused, re-added to
      # the quota, and the max-lifetime ceiling restarts from the wake.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-parked")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Fountain.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :suspended, raw: %{name: "test-sprite-parked"}}}
      end)

      # resume/1 is the explicit wake call (a probe on Sprites); the adapter
      # is the stubbing seam, so it needs its own stub here.
      stub(Fountain.Sandbox.Sprites, :resume, fn handle -> {:ok, handle} end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Conversations.wake_conversation(conv.id)
      # Same sandbox — no fresh sprite was provisioned.
      assert woken.sandbox_id == sandbox.id

      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "ready"
      assert %DateTime{} = reloaded.last_resumed_at
    end

    test "waking a suspended sandbox re-runs the quota gate" do
      # A parked sprite is free; waking it is compute again. A user at their
      # cap must be refused, exactly as if they were starting a conversation.
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 1)
      agent = insert_agent(user_id: user.id)

      insert_sandbox(user_id: user.id, status: "ready")

      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-capped")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Fountain.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :unknown, raw: %{}}} end)

      assert {:error, {:sandbox_quota_exceeded, _}} = Conversations.wake_conversation(conv.id)
      # Refused means still parked — the row must not be half-woken.
      assert Repo.reload(sandbox).status == "suspended"
    end

    test "a transient sprite probe failure does not give up a suspended sandbox" do
      # Falling to :create_new would retire the row and route the still-live
      # sprite — the agent's memory — to the reaper's destroy pass. Only a
      # definitive not-found may do that; anything else fails retryably.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-blip")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Fountain.Sandbox.Sprites, :get, fn _handle -> {:error, {:unavailable, :timeout}} end)

      assert {:error, :sprite_probe_failed} = Conversations.wake_conversation(conv.id)
      assert Repo.reload(sandbox).status == "suspended"
    end

    test "a transient sprite probe failure does not give up a ready sandbox either (#799)" do
      # A `ready` row whose server is gone (deploy, crash, partition) is the
      # same parked disk as a suspended one. Until #799 only `suspended` was
      # protected; a `ready` row fell to :create_new, was marked terminated,
      # and the reaper destroyed a sprite that was fine.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-blip-ready")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Fountain.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}
      end)

      reject(&Horde.DynamicSupervisor.start_child/2)

      assert {:error, :sprite_probe_failed} = Conversations.wake_conversation(conv.id)
      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "ready"
      assert is_nil(reloaded.terminated_at)
      assert Repo.reload(conv).sandbox_id == sandbox.id
    end

    test "a definitively gone sprite retires the suspended sandbox and provisions fresh" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-vanished")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Fountain.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Conversations.wake_conversation(conv.id)
      assert woken.sandbox_id != sandbox.id
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "returns {:ok, conv} creating fresh sandbox when sprite is gone" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-gone")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      fake_client = %{}

      stub(Fountain.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} creating fresh sandbox when sandbox is pending (not ready)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      # A `pending` sandbox with no server anywhere: the provision died with
      # its BEAM. After the registry settle window (#800) the wake gives up
      # waiting and provisions fresh.
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Conversations.wake_conversation(conv.id)
      assert woken.sandbox_id != sandbox.id
    end

    test "a pending sandbox whose server appears during the settle window is handed the prompt, not raced (#800)" do
      # `session/new` (POST /api/conversations) starts the server via Horde,
      # which may place it on another pod; the first prompt arrives ~30 ms
      # later on this pod, sees a `pending` row and — before #800 — missed
      # the registry and took :create_new: two servers, two sprites, ~21 s of
      # provisioning each, and a name conflict that killed the loser after
      # the fact, leaving an orphan `ready` row. The prompt path now waits
      # for the registry to catch up and hands the prompt to the server it
      # finds.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      test = self()

      # A stand-in for the first server: registers under the conversation's
      # name a beat after the wake starts looking, then relays the prompt
      # cast it receives.
      late_server =
        spawn_link(fn ->
          Process.sleep(40)
          {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv.id, nil)
          send(test, :registered)

          receive do
            {:"$gen_cast", {:initial_prompt, prompt, images}} ->
              send(test, {:handed_off, prompt, images})
          end
        end)

      # No second server, no second sandbox.
      reject(&Horde.DynamicSupervisor.start_child/2)

      assert {:ok, woken} = Conversations.wake_conversation(conv.id, "hello")
      assert_receive :registered
      assert_receive {:handed_off, "hello", []}, 500

      assert woken.sandbox_id == sandbox.id
      assert Repo.reload(sandbox).status == "pending"

      assert Repo.aggregate(
               from(s in Fountain.Conversations.Sandbox, where: s.user_id == ^user.id),
               :count
             ) == 1

      Process.exit(late_server, :kill)
    end

    test "returns {:ok, conv} when old sandbox is already terminated (mark_old_sandbox_terminated no-op)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, sprite_name: "test-sprite-terminated")
      {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "terminated"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      # sandbox status is "terminated" (not "ready"), so maybe_reuse_sandbox returns :create_new,
      # which calls create_fresh_sandbox_and_start -> mark_old_sandbox_terminated(sandbox.id)
      # where the sandbox is already terminated, hitting the no-op branch
      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end

    test "mark_old_sandbox_terminated handles deleted sandbox gracefully" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      # sandbox remains "pending" so maybe_reuse_sandbox returns :create_new
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      # Point the conversation at a non-existent sandbox_id (bypassing FK) so that
      # mark_old_sandbox_terminated receives an id whose get_sandbox returns nil,
      # hitting the nil -> :ok branch (line 635).
      ghost_sandbox_id = Ecto.UUID.generate()
      {:ok, ghost_uuid_bin} = Ecto.UUID.dump(ghost_sandbox_id)
      {:ok, conv_id_bin} = Ecto.UUID.dump(conv.id)

      # Temporarily disable FK checks, update the conversation to reference a
      # non-existent sandbox_id, then re-enable. This simulates the case where
      # a sandbox was deleted out-of-band (e.g., admin cleanup) so that
      # mark_old_sandbox_terminated receives an id whose get_sandbox returns nil.
      Ecto.Adapters.SQL.query!(Fountain.Repo, "SET session_replication_role = replica", [])

      Ecto.Adapters.SQL.query!(
        Fountain.Repo,
        "UPDATE conversations SET sandbox_id = $1 WHERE id = $2",
        [ghost_uuid_bin, conv_id_bin]
      )

      # Also delete the original sandbox record now that the FK is no longer referenced.
      Ecto.Adapters.SQL.query!(Fountain.Repo, "SET session_replication_role = DEFAULT", [])
      Fountain.Repo.delete!(sandbox)

      stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Conversations.wake_conversation(conv.id)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
end
