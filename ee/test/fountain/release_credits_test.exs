defmodule Fountain.Release.CreditsTest do
  @moduledoc """
  `Fountain.Release.start_credits/1` (#1086 phase 5): the opening grants on
  the day credits go live. `async: false` because it reads the global switch.
  """

  use Fountain.DataCase, async: false

  import ExUnit.CaptureIO

  alias Fountain.Accounts.User
  alias Fountain.Credits
  alias Fountain.Release

  @since ~U[2026-08-16 00:00:00Z]
  @now ~U[2026-08-16 06:00:00Z]

  defp subscriber(plan) do
    {:ok, user} =
      insert_active_user()
      |> User.billing_changeset(%{
        plan: plan,
        current_period_start: ~U[2026-08-01 00:00:00Z],
        current_period_end: ~U[2026-09-01 00:00:00Z]
      })
      |> Repo.update()

    user
  end

  defp trialer do
    {:ok, user} =
      insert_verified_user()
      |> User.billing_changeset(%{
        subscription_status: "trialing",
        trial_ends_at: ~U[2026-08-25 00:00:00Z]
      })
      |> Repo.update()

    user
  end

  test "refuses with no floor, counts on a dry run, grants once for real" do
    solo = subscriber("solo")
    team = subscriber("team")
    trial = trialer()
    # Canceled and comped get nothing.
    {:ok, _} =
      insert_active_user()
      |> User.billing_changeset(%{subscription_status: "canceled"})
      |> Repo.update()

    cfg = Application.get_env(:fountain, :credits)
    on_exit(fn -> Application.put_env(:fountain, :credits, cfg) end)
    Application.put_env(:fountain, :credits, Keyword.put(cfg, :pricing_since, nil))

    capture_io(:stderr, fn ->
      assert {:error, :pricing_since_unset} = Release.start_credits(now: @now)
    end)

    assert Credits.balance(solo.id) == 0

    out =
      capture_io(fn ->
        assert {:ok, 3} = Release.start_credits(dry_run: true, since: @since, now: @now)
      end)

    assert out =~ "2 active subscriber(s)"
    assert out =~ "1 live trial(s)"
    assert Credits.balance(solo.id) == 0

    capture_io(fn -> assert {:ok, 3} = Release.start_credits(since: @since, now: @now) end)
    # 16 of 31 days remain.
    assert Credits.balance(solo.id) == div(1000 * 16 + 15, 31)
    assert Credits.balance(team.id) == div(2500 * 16 + 15, 31)
    assert Credits.balance(trial.id) == 1000

    capture_io(fn -> assert {:ok, 0} = Release.start_credits(since: @since, now: @now) end)
    assert Credits.balance(solo.id) == div(1000 * 16 + 15, 31)

    # One row per real run, the rerun included: the task ran, even if it wrote nothing.
    assert 2 ==
             Repo.aggregate(
               from(e in Fountain.Audit.Event, where: e.action == "release.credits_started"),
               :count
             )
  end
end
