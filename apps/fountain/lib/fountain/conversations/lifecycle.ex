defmodule Fountain.Conversations.Lifecycle do
  @moduledoc """
  How long a sandbox is allowed to run unattended, and what crossing each
  bound costs.

  Two bounds, both off by setting the value to `nil` or `0`:

  * **Idle timeout** — no turn activity for this long and the sandbox is
    **suspended**: the ConversationServer stops, the sprite stays alive at
    sprites.dev and scales itself to zero, and the sandbox row parks in
    `suspended`. The next prompt reattaches to the same sprite — same disk,
    same runtime session, so the agent keeps its memory of the conversation.
    This is the common case: someone starts a run, reads the answer, closes
    the tab. See decisions/0017.

  * **Max lifetime** — a ceiling on a *continuous run*, measured from the
    sandbox's creation or its last wake from `suspended`
    (`last_resumed_at || inserted_at`). Crossing it **destroys** the sprite.
    It catches the case the idle bound cannot: a conversation that keeps
    itself busy forever, burning compute unattended.

  ## Why the split

  The original design (#233) destroyed the sprite on both bounds, on the
  premise that an idle sprite bills indefinitely. It doesn't — sprites scale
  to zero on their own — and #649 measured what the destroy costs: the
  runtime's session lives in the sandbox's filesystem, so resuming onto a new
  sprite fails on every path we have (`claude --resume` answers "No
  conversation found with session ID"; ACP `session/resume` answers `-32002
  Resource not found`). Fountain's own transcript survives either way — every
  `log_events` row still renders — but the agent's memory does not. So the
  idle bound, which exists for abandoned-not-runaway conversations, now parks
  instead of destroying, and only the max-lifetime ceiling still pays the
  #649 price. `explain/1` tells the user which one they got.

  Suspended sandboxes are never aged out — a parked sprite is treated as
  costing nothing (decisions/0017), and the disk it holds is the agent's
  memory.

  Setting the conversation itself to `terminated` on either bound would *not*
  be safe — it would make the conversation permanently unresumable, turning a
  cost control into data loss.
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

  The two bounds now promise different things and the copy must not blur
  them. A suspend keeps the sprite's disk, so the agent genuinely resumes
  with its memory; a max-lifetime reclaim destroys it, and the agent's
  context goes with it (#649). Telling someone "history is preserved" on the
  destroy path — or hedging on the suspend path — makes the true sentence
  discredit the other.
  """
  @spec explain(:idle | :max_lifetime) :: String.t()
  def explain(:idle), do: explain(:idle, :suspend)

  def explain(:max_lifetime) do
    "Sandbox reclaimed after reaching the #{hours(max_lifetime_seconds())} hour maximum " <>
      "lifetime. Send another prompt to continue — the transcript above is kept, but the " <>
      "agent starts a fresh session and will not remember the earlier turns."
  end

  @doc """
  What crossing the idle bound does on this provider.

  `:suspend` where the provider can park with the disk preserved (the
  `:suspend` capability); `:destroy` where it cannot — an idle sandbox on
  such a backend keeps billing, so the cost control wins over the agent's
  memory, exactly as the max-lifetime ceiling already prices it.

  This is the single place the degradation decision lives; the
  ConversationServer's idle reclaim and the reaper's park both consult it —
  the same change-both-together discipline as the clock in `check/4`.
  """
  @spec idle_action(atom()) :: :suspend | :destroy
  def idle_action(provider) when is_atom(provider) do
    if Fountain.Sandbox.supports?(provider, :suspend), do: :suspend, else: :destroy
  end

  @doc """
  The idle copy, by what actually happened. Same honesty rule as the two
  arms of `explain/1`: promise memory only where the disk survives.
  """
  @spec explain(:idle, :suspend | :destroy) :: String.t()
  def explain(:idle, :suspend) do
    "Sandbox suspended after #{minutes(idle_timeout_seconds())} minutes idle. " <>
      "Send another prompt to continue — the agent picks up right where it left off."
  end

  def explain(:idle, :destroy) do
    "Sandbox reclaimed after #{minutes(idle_timeout_seconds())} minutes idle. " <>
      "Send another prompt to continue — the transcript above is kept, but this sandbox " <>
      "provider cannot park an idle sandbox, so the agent starts a fresh session and " <>
      "will not remember the earlier turns."
  end

  defp minutes(nil), do: "?"
  defp minutes(seconds), do: div(seconds, 60)
  defp hours(nil), do: "?"
  defp hours(seconds), do: div(seconds, 3600)
end
