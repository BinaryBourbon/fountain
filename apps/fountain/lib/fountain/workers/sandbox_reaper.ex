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
    expired = expire_abandoned_sandboxes()

    result =
      case list_sprites() do
        {:ok, live_names} ->
          destroyed = destroy_dead_sprites(live_names)
          untracked = report_untracked(live_names)

          Logger.info(
            "reaper: released=#{released} expired=#{expired} destroyed=#{destroyed} " <>
              "untracked=#{untracked} live=#{MapSet.size(live_names)}"
          )

          :ok

        {:error, reason} ->
          # The stuck-row pass already ran and does not need sprites.dev, so its
          # work stands. Returning an error lets Oban retry the rest.
          Logger.warning("reaper: could not list sprites: #{inspect(reason)}")
          {:error, reason}
      end

    :telemetry.execute([:fountain, :reaper, :run], %{released: released, expired: expired}, %{})

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
      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: "failed",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      Logger.info(
        "reaper: released stuck sandbox #{sandbox.id} (#{sandbox.sprite_name}) " <>
          "after #{@stuck_after_minutes}m in #{sandbox.status}"
      )

      sandbox
    end)
    |> length()
  end

  # A live ConversationServer means provisioning is still in flight somewhere in
  # the cluster, however long it has taken. Horde's registry is cluster-wide, so
  # this is not just a local check.
  defp server_alive?(%Sandbox{conversations: conversations}) do
    Enum.any?(conversations, fn conv -> ConversationServer.whereis(conv.id) != nil end)
  end

  # ── pass 1b: ready sandboxes nobody is holding ────────────────────────────

  @doc """
  Marks `ready` sandboxes past their lifetime bound as terminated.

  This is the half of #167 that the ConversationServer cannot do. The server
  enforces its own idle timeout while it is alive, but a sandbox whose server
  died — a crash, a node that left the cluster, a deploy that happened to land
  between the rehydrator's scan and a reattach — has nothing watching it. The
  83-day-old sandbox in production was exactly that: `ready`, no server, alive
  since 2026-05-10.

  Activity is read from the conversation's most recent turn rather than from
  `sandboxes.updated_at` or `conversations.updated_at`, both of which get
  touched by bookkeeping the user had nothing to do with — the rehydrator moves
  `conversations.updated_at` on every boot, which would make an abandoned
  conversation look freshly active after each deploy.
  """
  def expire_abandoned_sandboxes do
    idle = Lifecycle.idle_timeout_seconds()
    max_lifetime = Lifecycle.max_lifetime_seconds()

    if is_nil(idle) and is_nil(max_lifetime) do
      0
    else
      now = DateTime.utc_now()

      Sandbox
      |> where([s], s.status == "ready")
      |> Repo.all()
      |> Repo.preload(:conversations)
      |> Enum.reject(&server_alive?/1)
      |> Enum.filter(&expired?(&1, now))
      |> Enum.map(&expire/1)
      |> length()
    end
  end

  defp expired?(sandbox, now) do
    Lifecycle.check(sandbox.inserted_at, last_activity_at(sandbox), false, now) != :ok
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

  defp expire(sandbox) do
    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{
        status: "terminated",
        terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Logger.info(
      "reaper: expired abandoned sandbox #{sandbox.id} (#{sandbox.sprite_name}) — " <>
        "ready with no live server past its lifetime bound"
    )

    # The conversation is deliberately left alone. It stays resumable, and the
    # next prompt provisions a fresh sandbox with the same runtime session.
    # The sprite itself is destroyed by pass 2 on this same run, now that the
    # row is terminal.
    sandbox
  end

  # ── pass 2: terminal rows whose sprite is still there ─────────────────────

  defp destroy_dead_sprites(live_names) do
    client = Fountain.SpritesClient.get!()

    Sandbox
    |> where([s], s.status in ^@terminal_statuses)
    |> select([s], {s.id, s.sprite_name})
    |> Repo.all()
    |> Enum.filter(fn {_id, name} -> MapSet.member?(live_names, name) end)
    |> Enum.take(@destroy_limit)
    |> Enum.count(fn {id, name} -> destroy(client, id, name) end)
  end

  defp destroy(client, sandbox_id, sprite_name) do
    # `Sprites.sprite/2` builds the handle; `get_sprite/2` only returns a map
    # and cannot be passed to destroy. We already know it exists — it came out
    # of the listing — so there is nothing to look up first.
    case Sprites.destroy(Sprites.sprite(client, sprite_name)) do
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

  # Paginated deliberately — see Fountain.SpritesClient.list_all_sprite_names/0.
  # A single `Sprites.list/2` call returns the first 50 and looks complete,
  # which for a function that decides what to delete is the worst possible
  # shape of wrong.
  defp list_sprites do
    Fountain.SpritesClient.list_all_sprite_names()
  rescue
    e -> {:error, e}
  end
end
