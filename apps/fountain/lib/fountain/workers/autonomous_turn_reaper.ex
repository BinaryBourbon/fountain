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
  a dead one — same reject-anything-alive-then-act-on-the-rest fold.
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
    |> Repo.all()
    |> Enum.reject(&server_alive?/1)
    |> Enum.map(fn turn ->
      :ok = Conversations.orphan_turn(turn, "stuck_running_no_server")

      Logger.info(
        "autonomous_turn_reaper: closed turn #{turn.id} " <>
          "(conversation #{turn.conversation_id}) stuck running since #{turn.started_at}"
      )

      turn
    end)
    |> length()
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
