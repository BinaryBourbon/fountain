defmodule Fountain.Workers.UnverifiedAccountPrunerTest do
  # async: false — the exemption list lives in application env, which is
  # global; a concurrent test would see this one's config.
  use Fountain.DataCase, async: false

  alias Fountain.Accounts.User
  alias Fountain.Workers.UnverifiedAccountPruner

  defp backdate(user, days_ago) do
    inserted =
      DateTime.utc_now() |> DateTime.add(-days_ago, :day) |> DateTime.truncate(:second)

    user |> Ecto.Changeset.change(inserted_at: inserted) |> Repo.update!()
  end

  setup do
    previous_days = Application.get_env(:fountain, :unverified_prune_after_days, 30)
    previous_exempt = Application.get_env(:fountain, :unverified_prune_exempt, [])

    on_exit(fn ->
      Application.put_env(:fountain, :unverified_prune_after_days, previous_days)
      Application.put_env(:fountain, :unverified_prune_exempt, previous_exempt)
    end)

    :ok
  end

  test "deletes only unverified accounts past the grace period" do
    stale = backdate(insert_user(), 45)
    fresh = insert_user()
    verified_stale = backdate(insert_verified_user(), 45)

    assert :ok = UnverifiedAccountPruner.perform(%Oban.Job{})

    refute Repo.get(User, stale.id)
    assert Repo.get(User, fresh.id)
    assert Repo.get(User, verified_stale.id)
  end

  test "an exempt substring protects an account, case-insensitively" do
    Application.put_env(:fountain, :unverified_prune_exempt, ["jhgaylor"])

    exempt = backdate(insert_user(%{"email" => "JHGaylor+bot-test-#{System.unique_integer([:positive])}@example.com"}), 45)
    doomed = backdate(insert_user(), 45)

    assert :ok = UnverifiedAccountPruner.perform(%Oban.Job{})

    assert Repo.get(User, exempt.id)
    refute Repo.get(User, doomed.id)
  end

  test "0 days disables the sweep entirely" do
    Application.put_env(:fountain, :unverified_prune_after_days, 0)
    stale = backdate(insert_user(), 400)

    assert :ok = UnverifiedAccountPruner.perform(%Oban.Job{})
    assert Repo.get(User, stale.id)
  end

  test "deletion leaves the audit trail delete_user writes" do
    stale = backdate(insert_user(), 45)
    assert :ok = UnverifiedAccountPruner.perform(%Oban.Job{})

    assert Enum.any?(
             Fountain.Audit._unsafe_list_recent(50),
             &(&1.action == "account.deleted" and
                 &1.metadata["user_id"] == stale.id and
                 &1.actor == "system:unverified_pruner")
           )
  end
end
