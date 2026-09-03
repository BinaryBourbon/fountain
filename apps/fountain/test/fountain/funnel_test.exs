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

  # An account that got a reply: a conversation, and a turn that ended
  # carrying assistant text. `insert_turn/2` writes the row directly, so the
  # funnel reads exactly what production's turn-ending write would have left.
  defp reply!(user, opts \\ []) do
    conv = Keyword.get_lazy(opts, :conversation, fn -> insert_conversation(user_id: user.id) end)

    insert_turn(conv, %{
      status: "completed",
      reply_text: Keyword.get(opts, :text, "the agent answered"),
      ended_at: Keyword.get(opts, :at, at(0))
    })
  end

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
      reply!(activated)

      # Every verified account holds the opening credit, so "funded" is the
      # ones that still have some: drain the others.
      funded = insert_verified_user()
      set!(funded, onboarding_completed_at: at(3))
      reply!(funded)
      for u <- [verified_only, onboarded, activated], do: drain!(u)

      summary = Funnel.summary_admin()

      assert stage(summary, :registered).count == 5
      assert stage(summary, :verified).count == 4
      assert stage(summary, :onboarded).count == 3
      assert stage(summary, :activated).count == 2
      assert stage(summary, :funded).count == 1

      assert stage(summary, :verified).conversion == 4 / 5
      assert stage(summary, :onboarded).conversion == 3 / 4
      assert stage(summary, :activated).conversion == 2 / 3
      assert stage(summary, :funded).conversion == 1 / 2
    end

    test "a positive balance counts as funded; a drained one does not" do
      _funded = insert_verified_user()
      drain!(insert_verified_user())

      assert stage(Funnel.summary_admin(), :funded).count == 1
    end
  end

  # ADR 0038: activation is the first conversation *with a reply*. Everything
  # short of that — a conversation row, a provisioned sandbox, a turn that ran
  # and said nothing — is an attempt, and an attempt is not an outcome.
  describe "summary_admin/0 — activation is the first reply" do
    test "a turn carrying assistant text counts as activated" do
      reply!(insert_verified_user())

      assert stage(Funnel.summary_admin(), :activated).count == 1
    end

    test "a conversation with no reply does not count" do
      user = insert_verified_user()
      insert_conversation(user_id: user.id)

      assert stage(Funnel.summary_admin(), :activated).count == 0
    end

    test "a turn that ran and produced no text does not count" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      insert_turn(conv, %{status: "completed", ended_at: at(0)})
      insert_turn(conv, %{status: "failed", reply_text: "", ended_at: at(0)})

      assert stage(Funnel.summary_admin(), :activated).count == 0
    end

    test "a provisioned sandbox does not count on its own" do
      user = insert_verified_user()
      {:ok, _} = Fountain.Billing.record_usage(user.id, "sandbox_provisioned", nil, nil)

      assert stage(Funnel.summary_admin(), :activated).count == 0
    end

    test "a turn still running does not count until it ends with a reply" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, %{status: "running"})

      assert stage(Funnel.summary_admin(), :activated).count == 0

      Repo.update!(
        Ecto.Changeset.change(turn, status: "completed", reply_text: "done", ended_at: at(0))
      )

      assert stage(Funnel.summary_admin(), :activated).count == 1
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

    test "activation timing uses the earliest replied turn" do
      user = insert_verified_user()
      set!(user, inserted_at: at(10), email_verified_at: at(9), onboarding_completed_at: at(8))

      # Two replies, at -5h and -2h across two conversations: the earlier wins.
      reply!(user, at: at(5))
      reply!(user, at: at(2))

      summary = Funnel.summary_admin()
      # onboarded at -8h, first reply at -5h → 3h
      assert_in_delta stage(summary, :activated).median_hours, 3.0, 0.01
    end

    test "a replied turn with no ended_at falls back to when its row was written" do
      user = insert_verified_user()
      set!(user, inserted_at: at(10), email_verified_at: at(9), onboarding_completed_at: at(8))

      turn = reply!(user, at: nil)
      Repo.update!(Ecto.Changeset.change(turn, inserted_at: at(4)))

      assert_in_delta stage(Funnel.summary_admin(), :activated).median_hours, 4.0, 0.01
    end
  end

  describe "summary_admin/0 — time to first reply" do
    test "nothing measured on an instance where nobody has replied" do
      insert_verified_user()

      ttfr = Funnel.summary_admin().time_to_first_reply

      assert ttfr.count == 0
      assert ttfr.median_hours == nil
      assert ttfr.p90_hours == nil
      assert ttfr.within_day_share == nil
    end

    test "median and p90 run from verification, not from onboarding" do
      # Five accounts verified 10 days ago, replying 1, 2, 3, 4 and 30 hours
      # later. Median is the third; nearest-rank p90 of five values is the
      # fifth, which is the point of a p90: the slow one is visible.
      for h <- [1, 2, 3, 4, 30] do
        user = insert_verified_user()
        set!(user, email_verified_at: at(240), onboarding_completed_at: at(240))
        reply!(user, at: at(240 - h))
      end

      ttfr = Funnel.summary_admin().time_to_first_reply

      assert ttfr.count == 5
      assert_in_delta ttfr.median_hours, 3.0, 0.01
      assert_in_delta ttfr.p90_hours, 30.0, 0.01
    end

    test "the within-a-day share counts only accounts a day has passed for" do
      # Verified 10 days ago, replied in an hour: in both halves.
      quick = insert_verified_user()
      set!(quick, email_verified_at: at(240))
      reply!(quick, at: at(239))

      # Verified 10 days ago, replied after two days: in the denominator only.
      slow = insert_verified_user()
      set!(slow, email_verified_at: at(240))
      reply!(slow, at: at(192))

      # Verified 10 days ago, never replied: in the denominator only.
      stalled = insert_verified_user()
      set!(stalled, email_verified_at: at(240))

      # Verified an hour ago and already replied: it has not had a day, so it
      # is in neither half. Counting it in the numerator alone would let the
      # share exceed 1.
      fresh = insert_verified_user()
      set!(fresh, email_verified_at: at(1))
      reply!(fresh, at: at(0.5))

      ttfr = Funnel.summary_admin().time_to_first_reply

      assert ttfr.count == 3
      assert ttfr.within_day == 1
      assert ttfr.within_day_of == 3
      assert_in_delta ttfr.within_day_share, 1 / 3, 0.001
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

      # An account that got a reply is not stalled, whatever else is true.
      activated = insert_verified_user()
      reply!(activated)

      # Unverified users are not in the stalled cohort.
      _unverified = insert_user()

      %{stalled: stalled} = Funnel.summary_admin()

      assert stalled.count == 3
      assert stalled.by_onboarding_state == %{"step_1" => 1, "step_3" => 2}
      # All three, and none: every verified account owns a starter agent
      # (ADR 0038). #1421 replaces this decomposition.
      assert stalled.built_agent == 3
      assert stalled.built_environment == 1
      assert stalled.built_nothing == 0
    end

    test "started: the stalled accounts that ran something and got nothing back" do
      # A conversation that never answered. This is the account the old
      # activation definition counted as activated.
      tried = insert_verified_user()
      insert_conversation(user_id: tried.id)

      # A conversation since deleted: its turns went with it, so the metering
      # row is the only surviving witness that anything ran. This is what the
      # usage-event union is still worth, one stage below activation.
      deleted = insert_verified_user()
      {:ok, _} = Fountain.Billing.record_usage(deleted.id, "sandbox_provisioned", nil, nil)

      # Built an agent, never ran it.
      _never = insert_verified_user() |> tap(&insert_agent(user_id: &1.id))

      %{stalled: stalled} = Funnel.summary_admin()

      assert stalled.count == 3
      assert stalled.started == 2
    end

    test "a non-provisioning usage event is not a start" do
      user = insert_verified_user()
      {:ok, _} = Fountain.Billing.record_usage(user.id, "turn_started", nil, nil)

      assert Funnel.summary_admin().stalled.started == 0
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
      assert Map.has_key?(measurements, :funded)
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
