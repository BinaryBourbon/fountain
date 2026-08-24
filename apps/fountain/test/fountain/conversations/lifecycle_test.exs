defmodule Fountain.Conversations.LifecycleTest do
  @moduledoc """
  Sandbox lifetime bounds.

  The bias throughout is that reclaiming too eagerly costs a re-provision on the
  next prompt while reclaiming too late bills indefinitely — but only because
  the conversation survives. These tests pin both halves: when a bound fires,
  and that the answer is a bound on the *sandbox*.
  """

  use ExUnit.Case, async: false

  alias Fountain.Conversations.Lifecycle

  defp with_config(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "configuration" do
    test "defaults are an hour idle and no ceiling (#936)" do
      with_config([sandbox_idle_timeout_minutes: nil, sandbox_max_lifetime_hours: nil], fn ->
        Application.delete_env(:fountain, :sandbox_idle_timeout_minutes)
        Application.delete_env(:fountain, :sandbox_max_lifetime_hours)

        assert Lifecycle.idle_timeout_seconds() == 3600
        assert Lifecycle.max_lifetime_seconds() == nil
      end)
    end

    test "0 disables a bound" do
      # The escape hatch for a self-hoster who wants the pre-#167 behaviour.
      with_config([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 0], fn ->
        assert Lifecycle.idle_timeout_seconds() == nil
        assert Lifecycle.max_lifetime_seconds() == nil
      end)
    end

    test "a string value is accepted" do
      # runtime.exs parses these, but application env can be set by hand too.
      with_config([sandbox_idle_timeout_minutes: "15"], fn ->
        assert Lifecycle.idle_timeout_seconds() == 900
      end)
    end

    test "nonsense disables rather than crashes the check" do
      # A bad env var must not take out every ConversationServer on its timer.
      with_config([sandbox_idle_timeout_minutes: "banana"], fn ->
        assert Lifecycle.idle_timeout_seconds() == nil
      end)
    end
  end

  describe "check/4" do
    test "a fresh, active sandbox is fine" do
      with_config([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert :ok = Lifecycle.check(ago(60), ago(10), false)
      end)
    end

    test "idle past the timeout expires" do
      with_config([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {:expired, :idle} = Lifecycle.check(ago(7200), ago(3601), false)
      end)
    end

    test "a running turn is activity, so idle does not fire" do
      # Otherwise a single long turn — the thing sandboxes exist for — would be
      # killed underneath the user at the hour mark.
      with_config([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert :ok = Lifecycle.check(ago(7200), ago(7200), true)
      end)
    end

    test "max lifetime fires even mid-turn" do
      # The bound an idle timeout cannot enforce: a conversation that keeps
      # itself permanently busy. A day is far past any legitimate turn.
      with_config([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {:expired, :max_lifetime} = Lifecycle.check(ago(90_000), DateTime.utc_now(), true)
      end)
    end

    test "max lifetime is reported in preference to idle" do
      with_config([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {:expired, :max_lifetime} = Lifecycle.check(ago(90_000), ago(90_000), false)
      end)
    end

    test "the default config never reaches the ceiling, however long the run (#936)" do
      with_config([sandbox_idle_timeout_minutes: nil, sandbox_max_lifetime_hours: nil], fn ->
        Application.delete_env(:fountain, :sandbox_idle_timeout_minutes)
        Application.delete_env(:fountain, :sandbox_max_lifetime_hours)
        # Ten days busy: still fine. Ten days idle: the idle bound, never the ceiling.
        assert :ok = Lifecycle.check(ago(864_000), DateTime.utc_now(), true)
        assert {:expired, :idle} = Lifecycle.check(ago(864_000), ago(864_000), false)
      end)
    end

    test "disabled bounds never expire, however old" do
      with_config([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 0], fn ->
        # The 83-day production sandbox, under an operator who opted out.
        assert :ok = Lifecycle.check(ago(83 * 86_400), ago(83 * 86_400), false)
      end)
    end

    test "one bound disabled does not disable the other" do
      with_config([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        assert :ok = Lifecycle.check(ago(3600), ago(3600), false)
        assert {:expired, :max_lifetime} = Lifecycle.check(ago(90_000), ago(90_000), false)
      end)
    end
  end

  describe "explain/1" do
    test "names the bound that fired and what to do next" do
      # From the user's side the sandbox simply vanished. This message is the
      # difference between a bug report and a shrug.
      with_config([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        idle = Lifecycle.explain(:idle)
        assert idle =~ "60 minutes idle"
        assert idle =~ "Send another prompt"

        assert Lifecycle.explain(:max_lifetime) =~ "24 hour"
        assert Lifecycle.explain(:max_lifetime) =~ "Send another prompt"
      end)
    end

    test "the two bounds promise exactly what each one keeps (#649, 0017)" do
      # A suspend keeps the sprite's disk — the agent's memory — so the idle
      # copy may promise a real resume. A max-lifetime reclaim destroys it, and
      # promising anything more than the transcript makes the agent's amnesia
      # read as a bug in the model. The copy must not blur the two.
      idle = Lifecycle.explain(:idle)
      assert idle =~ "suspended"
      assert idle =~ "picks up right where it left off"
      refute idle =~ "will not remember"

      max = Lifecycle.explain(:max_lifetime)
      refute max =~ "history is preserved"
      assert max =~ "will not remember"
      assert max =~ "transcript"
    end
  end
end
