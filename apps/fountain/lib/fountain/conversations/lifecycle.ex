defmodule Fountain.Conversations.Lifecycle do
  @moduledoc """
  How long a sandbox is allowed to exist.

  Nothing bounded this before. A sandbox lived until something explicitly
  terminated it, and `docs/primitives.md` told users "the sandbox exits when the
  conversation terminates **or a timeout hits**" — describing a safeguard that
  was never built. Production had a `ready` sandbox continuously alive since
  2026-05-10, 83 days idle, billing and holding a slot against its owner's
  concurrent-sandbox cap the whole time.

  Two bounds, both off by setting the value to `nil` or `0`:

  * **Idle timeout** — no turn activity for this long and the sandbox is
    reclaimed. This is the one that recovers abandoned conversations, which is
    the common case: someone starts a run, reads the answer, closes the tab.

  * **Max lifetime** — an absolute ceiling from sandbox creation, regardless of
    activity. Catches the case an idle timeout cannot: a conversation that keeps
    itself busy forever.

  ## What reclaiming costs

  Only the *sandbox* is torn down. The conversation row stays `idle`, which
  keeps it resumable — `assert_resumable/1` only refuses `terminated` and
  `failed`. The next prompt goes through `wake_conversation/2`, which sees a
  sandbox that is no longer `ready`, provisions a fresh one, and passes the
  persisted `runtime_session_id`.

  This module used to claim that the runtime then "resumes the same chat", and
  that the cost of reclaiming early was therefore "a re-provision on the next
  prompt, not lost work". **That is false, and #649 has the measurement.** The
  runtime's session lives in the *sandbox's* filesystem, and the environment
  checkpoint a fresh provision restores is taken before any turn ran, so it
  cannot contain one. Resuming onto a new sprite fails on every path we have:
  `claude --resume` answers "No conversation found with session ID" and ACP's
  `session/resume` answers `-32002 Resource not found`.

  So the honest asymmetry is narrower than the one the defaults were chosen
  under. Being wrong in the reclaiming direction costs the agent's memory of
  the conversation — Fountain's own transcript is untouched, every `log_events`
  row still renders, so the loss is invisible in the UI and visible only in the
  agent's answers. Being wrong in the other direction bills indefinitely.
  Reclaiming is still right; it is just not free, and `explain/1` says so
  rather than promising otherwise.

  Setting the conversation itself to `terminated` here would *not* be safe — it
  would make the conversation permanently unresumable, turning a cost control
  into data loss.
  """

  @default_idle_minutes 60
  @default_max_lifetime_hours 24

  @doc "Idle timeout in seconds, or `nil` when disabled."
  @spec idle_timeout_seconds() :: pos_integer() | nil
  def idle_timeout_seconds do
    to_seconds(
      Application.get_env(:fountain, :sandbox_idle_timeout_minutes, @default_idle_minutes),
      60
    )
  end

  @doc "Absolute sandbox lifetime in seconds, or `nil` when disabled."
  @spec max_lifetime_seconds() :: pos_integer() | nil
  def max_lifetime_seconds do
    to_seconds(
      Application.get_env(:fountain, :sandbox_max_lifetime_hours, @default_max_lifetime_hours),
      3600
    )
  end

  defp to_seconds(nil, _unit), do: nil
  defp to_seconds(0, _unit), do: nil
  defp to_seconds(n, unit) when is_integer(n) and n > 0, do: n * unit

  defp to_seconds(n, unit) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> to_seconds(i, unit)
      :error -> nil
    end
  end

  defp to_seconds(_, _), do: nil

  @doc """
  Which bound, if any, a sandbox has crossed.

  Returns `{:expired, :idle | :max_lifetime}` or `:ok`. `busy?` suppresses only
  the idle verdict: a turn in flight is activity by definition, while the
  absolute ceiling exists precisely for the conversation that never stops being
  busy.
  """
  @spec check(DateTime.t(), DateTime.t(), boolean(), DateTime.t()) ::
          {:expired, :idle | :max_lifetime} | :ok
  def check(started_at, last_activity_at, busy?, now \\ DateTime.utc_now()) do
    max_lifetime = max_lifetime_seconds()
    idle = idle_timeout_seconds()

    cond do
      max_lifetime && DateTime.diff(now, started_at) >= max_lifetime ->
        {:expired, :max_lifetime}

      not busy? && idle && DateTime.diff(now, last_activity_at) >= idle ->
        {:expired, :idle}

      true ->
        :ok
    end
  end

  @doc """
  Human-readable reason, for the stage event a client sees on the stream.

  Worth spending words on: from the user's side the sandbox simply went away,
  and an explanation is the difference between a bug report and a shrug.

  It must not overstate what survived. The transcript does; the agent's context
  does not (#649). Telling someone "history is preserved" and then having the
  agent answer as though the conversation never happened is worse than saying
  nothing, because they believe the first sentence and read the second as the
  model being broken.
  """
  @spec explain(:idle | :max_lifetime) :: String.t()
  def explain(:idle) do
    "Sandbox reclaimed after #{minutes(idle_timeout_seconds())} minutes idle. " <> resume_caveat()
  end

  def explain(:max_lifetime) do
    "Sandbox reclaimed after reaching the #{hours(max_lifetime_seconds())} hour maximum " <>
      "lifetime. " <> resume_caveat()
  end

  defp resume_caveat do
    "Send another prompt to continue — the transcript above is kept, but the " <>
      "agent starts a fresh session and will not remember the earlier turns."
  end

  defp minutes(nil), do: "?"
  defp minutes(seconds), do: div(seconds, 60)
  defp hours(nil), do: "?"
  defp hours(seconds), do: div(seconds, 3600)
end
