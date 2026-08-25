defmodule Fountain.FunnelTest do
  use Fountain.DataCase, async: true

  alias Fountain.Funnel

  defp set!(user, changes), do: Repo.update!(Ecto.Changeset.change(user, changes))

  # An account that cannot spend: the opening credit burned away.
  defp drain!(user) do
    {:ok, _} =
      Fountain.Credits.debit(user.id, Fountain.Credits.balance(user.id) + 1, "burn_turn",
        idempotency_key: "drain-#{user.id}"
      )

    Fountain.Repo.reload!(user)
  end

  defp at(hours_ago) do
    DateTime.utc_now()
    |> DateTime.add(-round(hours_ago * 3600), :second)
    |> DateTime.truncate(:second)
  end

  defp stage(summary, key), do: Enum.find(summary.stages, &(&1.key == key))

  describe "summary_admin/0 — stage counts" do
    test "empty database: zero counts, nil conversions and medians" do
      summary = Funnel.summary_admin()

      for s <- summary.stages do
        assert s.count == 0
        assert s.conversion == nil
        assert s.median_hours == nil
      end

      assert summary.stalled.count == 0
    end

    test "counts each stage cumulatively" do
      _registered_only = insert_user()
      verified_only = insert_verified_user()

      onboarded = insert_verified_user()
      set!(onboarded, onboarding_completed_at: at(1))

      activated = insert_verified_user()
      set!(activated, onboarding_completed_at: at(2))
      insert_conversation(user_id: activated.id)

      # Every verified account holds the opening credit, so "funded" is the
      # ones that still have some: drain the others.
      subscribed = insert_verified_user()
      set!(subscribed, onboarding_completed_at: at(3))
      insert_conversation(user_id: subscribed.id)
      for u <- [verified_only, onboarded, activated], do: drain!(u)

      summary = Funnel.summary_admin()

      assert stage(summary, :registered).count == 5
      assert stage(summary, :verified).count == 4
      assert stage(summary, :onboarded).count == 3
      assert stage(summary, :activated).count == 2
      assert stage(summary, :subscribed).count == 1

      assert stage(summary, :verified).conversion == 4 / 5
      assert stage(summary, :onboarded).conversion == 3 / 4
      assert stage(summary, :activated).conversion == 2 / 3
      assert stage(summary, :subscribed).conversion == 1 / 2
    end

    test "a positive balance counts as funded; a drained one does not" do
      _funded = insert_verified_user()
      drain!(insert_verified_user())

      assert stage(Funnel.summary_admin(), :subscribed).count == 1
    end
  end

  describe "summary_admin/0 — activation sources" do
    test "a usage event alone counts as activated (conversation may be deleted)" do
      user = insert_verified_user()
      {:ok, _} = Fountain.Billing.record_usage(user.id, "sandbox_provisioned", nil, nil)

      assert stage(Funnel.summary_admin(), :activated).count == 1
    end

    test "a conversation row alone counts as activated" do
      user = insert_verified_user()
      insert_conversation(user_id: user.id)

      assert stage(Funnel.summary_admin(), :activated).count == 1
    end

    test "non-provisioning usage events do not count as activation" do
      user = insert_verified_user()
      {:ok, _} = Fountain.Billing.record_usage(user.id, "turn_started", nil, nil)

      assert stage(Funnel.summary_admin(), :activated).count == 0
    end
  end

  describe "summary_admin/0 — timings" do
    test "median hours between stages" do
      # Two verified users: 2h and 4h from registration to verification.
      fast = insert_verified_user()
      set!(fast, inserted_at: at(10), email_verified_at: at(8))

      slow = insert_verified_user()
      set!(slow, inserted_at: at(10), email_verified_at: at(6))

      summary = Funnel.summary_admin()
      assert_in_delta stage(summary, :verified).median_hours, 3.0, 0.01
    end

    test "activation timing uses the earliest of conversation and usage event" do
      user = insert_verified_user()
      set!(user, inserted_at: at(10), email_verified_at: at(9), onboarding_completed_at: at(8))

      # Conversation at -2h, usage event at -5h: the event is earlier and wins.
      conv = insert_conversation(user_id: user.id)
      Repo.update!(Ecto.Changeset.change(conv, inserted_at: at(2)))

      {:ok, event} = Fountain.Billing.record_usage(user.id, "sandbox_provisioned", nil, nil)
      Repo.update!(Ecto.Changeset.change(event, inserted_at: at(5)))

      summary = Funnel.summary_admin()
      # onboarded at -8h, first activity at -5h → 3h
      assert_in_delta stage(summary, :activated).median_hours, 3.0, 0.01
    end
  end

  describe "summary_admin/0 — stalled breakdown" do
    test "verified users with no conversation, by how far they got" do
      nothing = insert_verified_user()
      set!(nothing, onboarding_state: "step_1")

      agent_builder = insert_verified_user()
      set!(agent_builder, onboarding_state: "step_3")
      insert_agent(user_id: agent_builder.id)

      env_builder = insert_verified_user()
      set!(env_builder, onboarding_state: "step_3")
      insert_env(user_id: env_builder.id)

      # Activated user is not stalled, whatever else is true.
      activated = insert_verified_user()
      insert_conversation(user_id: activated.id)

      # Unverified users are not in the stalled cohort.
      _unverified = insert_user()

      %{stalled: stalled} = Funnel.summary_admin()

      assert stalled.count == 3
      assert stalled.by_onboarding_state == %{"step_1" => 1, "step_3" => 2}
      assert stalled.built_agent == 1
      assert stalled.built_environment == 1
      assert stalled.built_nothing == 1
    end
  end

  describe "emit_telemetry/0" do
    test "executes a [:fountain, :funnel] event with all stage counts" do
      insert_verified_user()

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "funnel-test-#{inspect(ref)}",
        [:fountain, :funnel],
        fn _event, measurements, _meta, _config -> send(test_pid, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("funnel-test-#{inspect(ref)}") end)

      Funnel.emit_telemetry()

      assert_receive {^ref, measurements}
      assert measurements.registered == 1
      assert measurements.verified == 1
      assert measurements.activated == 0
      assert measurements.stalled_verified == 1
      assert Map.has_key?(measurements, :onboarded)
      assert Map.has_key?(measurements, :subscribed)
    end

    test "a tick that cannot reach the database logs and returns :ok instead of raising" do
      # telemetry_poller permanently drops a measurement whose tick raises,
      # so the boot tick racing Repo startup used to kill the funnel gauges
      # for the node's lifetime (#365). Reproduce that exact failure by
      # pointing this process's dynamic repo at a name that isn't started.
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "funnel-fail-test-#{inspect(ref)}",
        [:fountain, :funnel],
        fn _event, measurements, _meta, _config -> send(test_pid, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("funnel-fail-test-#{inspect(ref)}") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Fountain.Repo.put_dynamic_repo(:repo_that_is_not_started)

          try do
            assert Funnel.emit_telemetry() == :ok
          after
            Fountain.Repo.put_dynamic_repo(Fountain.Repo)
          end
        end)

      assert log =~ "funnel telemetry tick skipped"
      refute_received {^ref, _measurements}
    end
  end
end
