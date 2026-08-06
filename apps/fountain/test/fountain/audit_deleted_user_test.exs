defmodule Fountain.AuditDeletedUserTest do
  @moduledoc """
  An audit write that loses a race with account deletion keeps its row (#590).

  `DELETE /api/account` deletes the user inside the action, and the `:api`
  pipeline's audit plug records on the way out — after the row is gone. The
  insert still carried the old `user_id`, so it violated
  `audit_events_user_id_fkey`, `record/1` rescued, and the row vanished. The
  trail of a deletion is the last place that should have a hole in it.

  The row is kept attributed to nobody, which is where it was headed anyway:
  `user_id` is `on_delete: :nilify_all`, so an insert landing a moment earlier
  would have been accepted and then nilified by the same cascade.
  """

  use Fountain.DataCase, async: true

  import Ecto.Query

  alias Fountain.Accounts.Deletion
  alias Fountain.{Audit, Repo}

  defp orphan_events do
    Repo.all(from e in Audit.Event, where: is_nil(e.user_id))
  end

  describe "deletion leaves the existing trail intact" do
    test "rows survive and are nilified rather than deleted" do
      user = insert_verified_user()
      insert_agent(user_id: user.id)

      before = Audit.list_recent_for_user(user.id, 100)
      assert length(before) >= 2
      total_before = Repo.aggregate(from(e in Audit.Event), :count)

      {:ok, _} = Deletion.delete_user(user)

      # Not deleted — nilified. The count only goes up, by the
      # `account.deleted` event itself.
      assert Repo.aggregate(from(e in Audit.Event), :count) > total_before
      assert Audit.list_recent_for_user(user.id, 100) == []

      actions = orphan_events() |> Enum.map(& &1.action)
      assert "account.registered" in actions
      assert "agent.created" in actions
      assert "account.deleted" in actions
    end

    test "account.deleted still says who, because it denormalises" do
      # The one row that keeps its identity, deliberately — everything else
      # stops naming anybody, which is the point of the nilify (ADR 0009).
      user = insert_verified_user()
      {:ok, _} = Deletion.delete_user(user)

      event = Enum.find(orphan_events(), &(&1.action == "account.deleted"))
      assert event.user_id == nil
      assert event.metadata["user_id"] == user.id
      assert event.metadata["email"] == user.email
    end
  end

  describe "a write that loses the race to the cascade" do
    test "is kept, attributed to nobody, instead of being dropped" do
      user = insert_verified_user()
      user_id = user.id

      {:ok, _} = Deletion.delete_user(user)

      # Exactly what the audit plug does on the way out of DELETE /api/account:
      # record with the id of a user that no longer exists.
      assert {:ok, event} =
               Audit.record(%{
                 user_id: user_id,
                 action: "DELETE /api/account",
                 resource_type: "account",
                 actor: "api",
                 request_ip: "203.0.113.7",
                 metadata: %{"status" => 204}
               })

      assert event.user_id == nil
      assert event.action == "DELETE /api/account"
      assert event.actor == "api"
      assert event.request_ip == "203.0.113.7"
      assert event.metadata["status"] == 204
    end

    test "the deleted account's id is not smuggled back into metadata" do
      # Nilifying is what makes a deleted account stop naming anybody. Putting
      # the id in metadata to keep the row correlatable would defeat that on
      # every self-deleting path.
      user = insert_verified_user()
      user_id = user.id

      {:ok, _} = Deletion.delete_user(user)

      {:ok, event} =
        Audit.record(%{
          user_id: user_id,
          action: "DELETE /api/account",
          resource_type: "account",
          actor: "api"
        })

      refute inspect(event.metadata) =~ user_id
    end

    test "a genuinely invalid event is still refused" do
      # The retry is scoped to the user_id foreign key. A different failure
      # must not be quietly rewritten into a system event.
      assert {:error, %Ecto.Changeset{}} =
               Audit.record(%{resource_type: "thing", actor: "api"})
    end

    test "an unrelated foreign key is not treated as a deleted user" do
      # Guard against the check matching on "any FK error": only :user_id
      # counts, because only :user_id is nullable-by-design here.
      user = insert_verified_user()

      assert {:ok, event} =
               Audit.record(%{
                 user_id: user.id,
                 action: "agent.created",
                 resource_type: "agent",
                 actor: "ui"
               })

      assert event.user_id == user.id
    end
  end

end

defmodule Fountain.AuditDeletedUserEndToEndTest do
  @moduledoc """
  The actual route that produced #590, driven for real rather than simulated.
  """

  use FountainWeb.ConnCase, async: true

  import Ecto.Query

  alias Fountain.{Audit, Repo}

  test "DELETE /api/account leaves both the semantic event and the request row",
       %{conn: conn} do
    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)

    conn
    |> authed_with_key(raw_key)
    |> delete_json("/api/account", %{"confirm" => user.email})
    |> json_response(200)

    refute Fountain.Accounts.get_user(user.id)

    actions =
      Repo.all(from e in Audit.Event, where: is_nil(e.user_id), select: e.action)

    # The pair a support question needs: what happened, and the request that
    # did it. Before #590 the plug's row lost a race with the cascade and was
    # dropped, so only the first of these existed.
    assert "account.deleted" in actions
    assert "DELETE /api/account" in actions

    request_row =
      Repo.one(
        from e in Audit.Event,
          where: e.action == "DELETE /api/account",
          limit: 1
      )

    assert request_row.user_id == nil
    assert request_row.actor == "api"
    assert request_row.metadata["status"] == 200
  end
end
