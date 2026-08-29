defmodule Fountain.Workers.AutonomousTurnReaper do
  @moduledoc """
  Closes turns stuck `running` with no live `ConversationServer` behind
  them (#1197).

  ## Why this exists

  `ConversationServer` arms a 10-minute `autonomous_quiet` watchdog for
  every autonomous turn (`arm_autonomous_quiet/1`), but the timer lives
  only in that GenServer's process memory. If the process exits before it
  fires — a deploy, a Horde rebalance, any `{:stop, :normal, _}` — the
  watchdog is gone with it. `ConversationServer.terminate/2` now closes
  the turn itself on a *graceful* exit (#1197), which covers the common
  case, but a hard crash or a SIGKILL never reaches `terminate/2` at all,
  and a node that leaves the cluster mid-turn may not get a restart
  either. Nothing else was sweeping for that: reconciliation otherwise
  only happens at app boot (the rehydrator) or when the next
  prompt/interrupt wakes the conversation — which an autonomous turn,
  sitting at `presence: working` and refusing every message as busy,
  never gets on its own (#1179: 4+ hours, in production, before a human
  noticed).

  ## Deadline

  A turn's `started_at` past `@stuck_after_minutes`, deliberately longer
  than the watchdog's own 10 minutes: the watchdog is what closes a
  *quiet* turn while its server is alive and can tell idle apart from
  working; this sweep has no such signal; it only knows a turn is
  `running` and its server is gone. A turn genuinely still working at 10
  minutes is not stuck, so the bound is wider — long enough that a false
  positive (closing a turn some other node still owns) would already
  mean Horde's registry has been wrong for `@stuck_after_minutes`
  straight, not just slow to converge. `Turn` carries no `updated_at`
  (see the schema), so `started_at` is the only clock available
  regardless of the bound chosen.

  ## Pattern

  Modeled directly on `SandboxReaper.release_stuck_sandboxes/0`: same
  `status in [...] and cutoff` query shape, same
  `ConversationServer.whereis/1` liveness check — cluster-wide through
  Horde's registry, so a live server on another node is not mistaken for
  a dead one — same reject-anything-alive-then-act-on-the-rest fold, same
  per-run cap (`@turn_stuck_limit`, mirroring `SandboxReaper`'s
  `@destroy_limit`) so a large historical backlog drains over several
  runs instead of firing every close — each one a `log_events` insert, a
  PubSub broadcast, and a tenant webhook dispatch — in one burst
  (review, #1197).

  ## What this does not fully close (review, #1197)

  Aliveness is re-checked immediately before each write rather than once
  for the whole batch, which shrinks but does not eliminate the window
  between "no live server" and "orphaned": a server can still attach in
  the gap between that check and the write landing. A cluster partition
  lasting the full `@stuck_after_minutes` can also make `whereis/1`
  report `nil` for a server that is very much alive on the unreachable
  side (the #799/#801 class) — `SandboxReaper` compensates for its own
  version of this with `@abandoned_grace_minutes` against
  `sandboxes.updated_at`, which the wake path touches; `turns` has no
  such column (`updated_at: false`) and this worker does not yet have an
  equivalent guard. Left open pending a decision on what signal to key
  it against.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, Turn}
  alias Fountain.Repo

  # Wider than the 10-minute `autonomous_quiet` watchdog on purpose — see
  # the moduledoc. Overridable in tests the same way the watchdog itself is.
  @stuck_after_minutes 30

  # A cap per run, so a large backlog drains over several runs instead of
  # firing hundreds of closes — each one a log_events insert, a PubSub
  # broadcast, and a tenant webhook dispatch — in one burst. Mirrors
  # SandboxReaper's `@destroy_limit` (review, #1197).
  @turn_stuck_limit 25

  @impl Oban.Worker
  def perform(_job) do
    closed = sweep_stuck_turns()

    Logger.info("autonomous_turn_reaper: closed=#{closed}")

    :telemetry.execute([:fountain, :autonomous_turn_reaper, :run], %{closed: closed}, %{})

    :ok
  end

  @doc false
  def sweep_stuck_turns do
    cutoff = DateTime.utc_now() |> DateTime.add(-stuck_after_minutes() * 60, :second)

    Turn
    |> where([t], t.status == "running" and t.started_at < ^cutoff)
    |> order_by([t], asc: t.started_at)
    |> limit(^@turn_stuck_limit)
    |> Repo.all()
    # Re-checked here, immediately before the write, rather than once for
    # the whole batch — shrinks (does not eliminate) the window a server
    # could attach in between. See the moduledoc for what is still open.
    |> Enum.reject(&server_alive?/1)
    |> Enum.map(fn turn ->
      {:ok, _turn, conv} = Conversations._unsafe_orphan_turn(turn, "stuck_running_no_server")

      record_reap(conv, turn)

      Logger.info(
        "autonomous_turn_reaper: closed turn #{turn.id} " <>
          "(conversation #{turn.conversation_id}) stuck running since #{turn.started_at}"
      )

      turn
    end)
    |> length()
  end

  # A turn stuck running with nobody live behind it is not a tenant-chosen
  # outcome, so — same reasoning as `SandboxReaper.record_reap/3` (#551) —
  # it gets its own line in the tenant's audit trail rather than existing
  # only in the server log.
  defp record_reap(conv, %Turn{} = turn) do
    Fountain.Audit.record(%{
      user_id: conv.user_id,
      action: "conversation.turn.reaped",
      resource_type: "turn",
      resource_id: turn.id,
      actor: "system:autonomous_turn_reaper",
      metadata: %{
        "conversation_id" => turn.conversation_id,
        "turn_number" => turn.turn_number,
        "started_at" => turn.started_at,
        "stuck_after_minutes" => stuck_after_minutes()
      }
    })
  end

  # A live ConversationServer means the turn is still someone's, however
  # long it has taken — this must never close a turn a server is actively
  # working. Horde's registry is cluster-wide, so this is not just a local
  # check, the same guarantee `SandboxReaper.server_alive?/1` relies on.
  defp server_alive?(%Turn{conversation_id: conversation_id}) do
    ConversationServer.whereis(conversation_id) != nil
  end

  defp stuck_after_minutes do
    Application.get_env(
      :fountain,
      :autonomous_turn_reaper_stuck_after_minutes,
      @stuck_after_minutes
    )
  end
end
