defmodule Fountain.FeatureFlagsTest do
  # Mutates global app env (the PostHog key, the overrides), so not async.
  use ExUnit.Case, async: false

  alias Fountain.FeatureFlags

  @user_id "11111111-1111-1111-1111-111111111111"

  setup do
    previous = %{
      key: Application.get_env(:fountain, :posthog_project_api_key),
      overrides: Application.get_env(:fountain, :feature_flag_overrides)
    }

    FeatureFlags.reset()

    on_exit(fn ->
      restore(:posthog_project_api_key, previous.key)
      restore(:feature_flag_overrides, previous.overrides)
      FeatureFlags.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp posthog_on, do: Application.put_env(:fountain, :posthog_project_api_key, "phc_test")
  defp posthog_off, do: Application.delete_env(:fountain, :posthog_project_api_key)

  defp stub_flags(flags) do
    Req.Test.stub(FeatureFlags, fn conn ->
      Req.Test.json(conn, %{"flags" => Map.new(flags, fn {k, v} -> {k, %{"enabled" => v}} end)})
    end)
  end

  defp stub_down do
    Req.Test.stub(FeatureFlags, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
  end

  describe "without PostHog" do
    test "every flag reads off" do
      posthog_off()
      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "a static override turns a flag on for everyone" do
      posthog_off()
      Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => true})
      assert FeatureFlags.enabled?(:team_comms, @user_id)
      assert FeatureFlags.enabled?(:team_comms, %{id: @user_id})
      # An override applies even with no user to ask about.
      assert FeatureFlags.enabled?(:team_comms, nil)
    end

    test "an unknown flag atom is a KeyError, not a silent off" do
      assert_raise KeyError, fn -> FeatureFlags.enabled?(:no_such_flag, @user_id) end
    end
  end

  describe "with PostHog" do
    setup do
      posthog_on()
      :ok
    end

    test "reads the flag for the user" do
      stub_flags(%{"team_comms" => true})
      assert FeatureFlags.enabled?(:team_comms, @user_id)

      stub_flags(%{"team_comms" => false})
      FeatureFlags.reset()
      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "a flag PostHog does not mention is off" do
      stub_flags(%{"something_else" => true})
      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "also reads the older /decide shape" do
      Req.Test.stub(FeatureFlags, fn conn ->
        Req.Test.json(conn, %{"featureFlags" => %{"team_comms" => true}})
      end)

      assert FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "a static override wins over PostHog" do
      stub_flags(%{"team_comms" => true})
      Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => false})
      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "caches the answer: a second call does not hit PostHog" do
      test = self()

      Req.Test.stub(FeatureFlags, fn conn ->
        send(test, :posthog_called)
        Req.Test.json(conn, %{"flags" => %{"team_comms" => %{"enabled" => true}}})
      end)

      assert FeatureFlags.enabled?(:team_comms, @user_id)
      assert_received :posthog_called
      assert FeatureFlags.enabled?(:team_comms, @user_id)
      refute_received :posthog_called
    end

    test "no user to ask about reads off without a call" do
      Req.Test.stub(FeatureFlags, fn _conn -> flunk("PostHog should not be called") end)
      refute FeatureFlags.enabled?(:team_comms, nil)
    end
  end

  describe "when PostHog is down" do
    setup do
      posthog_on()
      :ok
    end

    test "with no cached answer every flag reads off — never on" do
      stub_down()
      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "a 5xx is an outage too" do
      Req.Test.stub(FeatureFlags, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "the last answer it gave is kept — on stays on" do
      stub_flags(%{"team_comms" => true})
      assert FeatureFlags.enabled?(:team_comms, @user_id)

      # Expire the cache entry, then take PostHog down.
      age_cache(@user_id)
      stub_down()
      assert FeatureFlags.enabled?(:team_comms, @user_id)
    end

    test "the last answer it gave is kept — off stays off" do
      stub_flags(%{"team_comms" => false})
      refute FeatureFlags.enabled?(:team_comms, @user_id)

      age_cache(@user_id)
      stub_down()
      refute FeatureFlags.enabled?(:team_comms, @user_id)
    end
  end

  # Push the cached entry's timestamp into the past so the next read refetches.
  defp age_cache(distinct_id) do
    [{^distinct_id, flags, _at}] = :ets.lookup(FeatureFlags.table(), distinct_id)

    :ets.insert(
      FeatureFlags.table(),
      {distinct_id, flags, System.monotonic_time(:millisecond) - 600_000}
    )
  end
end
