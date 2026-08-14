defmodule Fountain.Workers.SandboxReaper do
  @moduledoc """
  Reconciles the `sandboxes` table against what actually exists at sprites.dev.

  ## What leaks, and how

  Both destroy call sites in `ConversationServer` discard the result —
  `_ = Sprites.destroy(sprite)` — and then mark the row `terminated` or
  `failed` regardless. So any destroy that fails for a transient reason leaves a
  sprite alive with a database row that says it is gone, and nothing ever looks
  again. This does not need a hard BEAM crash; the ordinary path is enough.

  Measured against production when this was written: 114 sprites existed at
  sprites.dev, 7 of them with a terminal sandbox row. The rest of the drift is
  historical (102 sprites with no row at all, from the pre-rename `aod-*` era)
  and 443 rows whose sprite is already gone.

  The other half is quota. `Fountain.Quotas` counts `pending`, `starting` and
  `ready` toward a tenant's concurrent-sandbox cap, deliberately — a sprite
  bills from the moment provisioning starts. A row stuck in `pending` because
  the BEAM died mid-provision therefore consumes cap forever, and a
  default-limit tenant with a few of those cannot start a conversation at all,
  with no self-serve way out.

  ## Three passes, in descending order of confidence

  1. **Release stuck rows.** `pending`/`starting` past the grace period with no
     live `ConversationServer` become `failed`. This frees quota and is safe:
     the row already cannot be used for anything.

  2. **Destroy sprites we know are dead.** A sandbox row in a terminal state
     whose sprite still exists at sprites.dev. Unambiguously ours,
     unambiguously finished.

  3. **Count sprites we do not recognise, and touch nothing.** Reported as a
     log line and a telemetry measurement.

  Pass 3 is deliberately inert. A sprite with no row is not proof of a leak: the
  same `SPRITES_TOKEN` may be in a developer's shell or a staging instance, and
  a sprite created seconds ago may simply not have committed its row yet.
  Production currently holds a `jake-*` sprite that is exactly this case.
  Destroying by absence-of-evidence would eventually delete someone's live work,
  and unlike a missed sprite that mistake cannot be undone. Cleaning up the
  legacy `aod-*` sprites is a one-off an operator can do by hand, having looked
  at the list.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, Lifecycle, Sandbox, Turn}
  alias Fountain.Repo

  # Long enough to clear the slowest legitimate provision: package installs get
  # 300s per command and a clone gets 600s, and several can run in sequence.
  # Being late to release a stuck row costs a little quota; being early kills a
  # sandbox that was still starting.
  @stuck_after_minutes 60

  # A cap per run, so a large backlog drains over several hours instead of
  # firing hundreds of destroy calls at sprites.dev in one burst.
  @destroy_limit 25

  @terminal_statuses ~w(terminated failed)
  @active_statuses ~w(pending starting)

  @impl Oban.Worker
  def perform(_job) do
    released = release_stuck_sandboxes()
    {parked, expired} = sweep_abandoned_sandboxes()

    result =
      case list_sprites() do
        {:ok, live_names} ->
          destroyed = destroy_dead_sprites(live_names)
          untracked = report_untracked(live_names)

          Logger.info(
            "reaper: released=#{released} parked=#{parked} expired=#{expired} " <>
              "destroyed=#{destroyed} untracked=#{untracked} live=#{MapSet.size(live_names)}"
          )

          :ok

        {:error, reason} ->
          # The stuck-row pass already ran and does not need sprites.dev, so its
          # work stands. Returning an error lets Oban retry the rest.
          Logger.warning("reaper: could not list sprites: #{inspect(reason)}")
          {:error, reason}
      end

    # `parked` is its own measurement: parks are reversible bookkeeping, and
    # folding them into `expired` would silently change what that metric means.
    :telemetry.execute(
      [:fountain, :reaper, :run],
      %{released: released, parked: parked, expired: expired},
      %{}
    )

    result
  end

  # ── pass 1: rows stuck mid-provision ──────────────────────────────────────

  @doc false
  def release_stuck_sandboxes do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stuck_after_minutes * 60, :second)

    Sandbox
    |> where([s], s.status in ^@active_statuses and s.updated_at < ^cutoff)
    |> Repo.all()
    |> Repo.preload(:conversations)
    |> Enum.reject(&server_alive?/1)
    |> Enum.map(fn sandbox ->
      was = sandbox.status

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: "failed",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      Logger.info(
        "reaper: released stuck sandbox #{sandbox.id} (#{sandbox.sprite_name}) " <>
          "after #{@stuck_after_minutes}m in #{sandbox.status}"
      )

      record_reap(sandbox, "sandbox.released_stuck", %{
        "previous_status" => was,
        "stuck_after_minutes" => @stuck_after_minutes
      })

      sandbox
    end)
    |> length()
  end

  # A live ConversationServer means provisioning is still in flight somewhere in
  # the cluster, however long it has taken. Horde's registry is cluster-wide, so
  # this is not just a local check.
  # A sandbox the tenant did not stop, ending for a reason only the reaper
  # knows. Attributed to the worker so "my agent's sandbox vanished" has an
  # answer in the tenant's own trail rather than only in the server log —
  # `admin.sandbox.reaped` covered the admin-clicked path and nothing covered
  # this one (#551).
  defp record_reap(%Sandbox{} = sandbox, action, metadata) do
    Fountain.Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: "system:sandbox_reaper",
      metadata: Map.put(metadata, "sprite_name", sandbox.sprite_name)
    })
  end

  defp server_alive?(%Sandbox{conversations: conversations}) do
    Enum.any?(conversations, fn conv -> ConversationServer.whereis(conv.id) != nil end)
  end

  # ── pass 1b: ready sandboxes nobody is holding ────────────────────────────

  # A `ready` row whose server died mid-wake looks identical to an abandoned
  # one until the new server registers in Horde — whose registry is an async
  # CRDT, so `server_alive?/1` can briefly miss a live server on another node.
  # The wake path touches `updated_at` when it flips `suspended → ready`, so a
  # grace period on `updated_at` makes a just-woken row untouchable for far
  # longer than registry propagation takes.
  @abandoned_grace_minutes 15

  @doc """
  Sweeps `ready` sandboxes with no live server past a lifetime bound: past the
  idle bound they are parked to `suspended` (the sprite stays, scaled to zero,
  and the next prompt reattaches — decisions/0017); past the max-lifetime
  ceiling they are terminated, and pass 2 destroys the sprite this same run.

  This is the half of #167 that the ConversationServer cannot do. The server
  enforces its own bounds while it is alive, but a sandbox whose server
  died — a crash, a node that left the cluster, a deploy that happened to land
  between the rehydrator's scan and a reattach — has nothing watching it. The
  83-day-old sandbox in production was exactly that: `ready`, no server, alive
  since 2026-05-10.

  `suspended` rows deliberately match no pass: that is the durable resting
  state, aged out by nothing (decisions/0017).

  Activity is read from the conversation's most recent turn rather than from
  `sandboxes.updated_at` or `conversations.updated_at`, both of which get
  touched by bookkeeping the user had nothing to do with — the rehydrator moves
  `conversations.updated_at` on every boot, which would make an abandoned
  conversation look freshly active after each deploy.

  Returns `{parked, expired}`.
  """
  def sweep_abandoned_sandboxes do
    idle = Lifecycle.idle_timeout_seconds()
    max_lifetime = Lifecycle.max_lifetime_seconds()

    if is_nil(idle) and is_nil(max_lifetime) do
      {0, 0}
    else
      now = DateTime.utc_now()
      grace_cutoff = DateTime.add(now, -@abandoned_grace_minutes * 60, :second)

      verdicts =
        Sandbox
        |> where([s], s.status == "ready" and s.updated_at < ^grace_cutoff)
        |> Repo.all()
        |> Repo.preload(:conversations)
        |> Enum.reject(&server_alive?/1)
        |> Enum.map(&{&1, check_bounds(&1, now)})

      parked = for {sandbox, {:expired, :idle}} <- verdicts, do: park(sandbox)
      expired = for {sandbox, {:expired, :max_lifetime}} <- verdicts, do: expire(sandbox)

      {length(parked), length(expired)}
    end
  end

  # Same clock as ConversationServer.sandbox_clock_start/1: the max-lifetime
  # ceiling measures a continuous run, restarting on a wake from `suspended`.
  defp check_bounds(sandbox, now) do
    started_at = sandbox.last_resumed_at || sandbox.inserted_at
    Lifecycle.check(started_at, last_activity_at(sandbox), false, now)
  end

  # Newest turn across the sandbox's conversations, falling back to when the
  # sandbox itself was created for one that never took a turn.
  defp last_activity_at(%Sandbox{inserted_at: inserted_at, conversations: convs}) do
    conv_ids = Enum.map(convs, & &1.id)

    latest =
      if conv_ids == [] do
        nil
      else
        Turn
        |> where([t], t.conversation_id in ^conv_ids)
        |> select([t], max(t.inserted_at))
        |> Repo.one()
      end

    latest || inserted_at
  end

  # Idle with no server: the server that would have suspended it is gone, so
  # park it here. Reversible bookkeeping — the sprite stays, and the next
  # prompt wakes it through the ordinary reattach path.
  defp park(sandbox) do
    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "suspended"})

    Logger.info(
      "reaper: parked idle sandbox #{sandbox.id} (#{sandbox.sprite_name}) — " <>
        "ready with no live server past the idle bound"
    )

    record_reap(sandbox, "sandbox.suspended", %{"reason" => "idle with no live server"})

    sandbox
  end

  defp expire(sandbox) do
    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{
        status: "terminated",
        terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Logger.info(
      "reaper: expired abandoned sandbox #{sandbox.id} (#{sandbox.sprite_name}) — " <>
        "ready with no live server past the max-lifetime ceiling"
    )

    record_reap(sandbox, "sandbox.expired", %{"reason" => "past max lifetime"})

    # The conversation is deliberately left alone. It stays resumable, and the
    # next prompt provisions a fresh sandbox (the runtime session on the
    # destroyed disk is lost — the price of the ceiling, see decisions/0017).
    # The sprite itself is destroyed by pass 2 on this same run, now that the
    # row is terminal.
    sandbox
  end

  # ── pass 2: terminal rows whose sprite is still there ─────────────────────

  defp destroy_dead_sprites(live_names) do
    Sandbox
    |> where([s], s.status in ^@terminal_statuses)
    |> select([s], {s.id, s.sprite_name})
    |> Repo.all()
    |> Enum.filter(fn {_id, name} -> MapSet.member?(live_names, name) end)
    |> Enum.take(@destroy_limit)
    |> Enum.count(fn {id, name} -> destroy(id, name) end)
  end

  defp destroy(sandbox_id, sprite_name) do
    # build_handle/2 is pure — we already know the sandbox exists (it came
    # out of the listing), so there is nothing to look up first.
    case Fountain.Sandbox.destroy(Fountain.Sandbox.build_handle(:sprites, sprite_name)) do
      :ok ->
        Logger.info("reaper: destroyed leaked sprite #{sprite_name} (sandbox #{sandbox_id})")
        true

      {:error, reason} ->
        # Left for the next run rather than retried here; the row stays terminal
        # either way, so nothing is lost by being slow about it.
        Logger.warning("reaper: destroy failed for #{sprite_name}: #{inspect(reason)}")
        false
    end
  end

  # ── pass 3: sprites with no row — counted, never touched ──────────────────

  @doc false
  def report_untracked(live_names) do
    known =
      Sandbox
      |> select([s], s.sprite_name)
      |> Repo.all()
      |> MapSet.new()

    untracked = MapSet.difference(live_names, known)
    count = MapSet.size(untracked)

    if count > 0 do
      sample = untracked |> Enum.sort() |> Enum.take(10) |> Enum.join(", ")

      Logger.info(
        "reaper: #{count} sprite(s) at sprites.dev have no sandbox row and were " <>
          "left alone (sample: #{sample})"
      )
    end

    :telemetry.execute([:fountain, :reaper, :untracked], %{count: count}, %{})
    count
  end

  # ── sprites.dev ───────────────────────────────────────────────────────────

  # Paginated deliberately inside the adapter — a first-page-only listing
  # looks complete, which for a function that decides what to delete is the
  # worst possible shape of wrong; the adapter returns {:error, :truncated}
  # rather than a partial view.
  defp list_sprites do
    Fountain.Sandbox.list_all_names(:sprites)
  rescue
    e -> {:error, e}
  end
end
