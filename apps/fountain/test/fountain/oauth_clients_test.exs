defmodule Fountain.OAuthClientsTest do
  @moduledoc """
  The registry of OAuth clients a tenant registered for itself (#1125): what
  one account may write, what it may never write, and what the trail keeps.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias Fountain.OAuth

  describe "create_client/3" do
    test "caps how many clients one account may register" do
      user = insert_verified_user()

      for n <- 1..25 do
        {:ok, _} =
          OAuth.create_client(user.id, %{
            "name" => "App #{n}",
            "redirect_uris" => ["https://app#{n}.test/callback"]
          })
      end

      assert {:error, changeset} =
               OAuth.create_client(user.id, %{
                 "name" => "One too many",
                 "redirect_uris" => ["https://nope.test/callback"]
               })

      assert "at most 25 apps per account" in errors_on(changeset).base
      assert length(OAuth.list_clients(user.id)) == 25

      # The ceiling is per account, not per deployment.
      assert {:ok, _} =
               OAuth.create_client(insert_verified_user().id, %{
                 "name" => "Someone else",
                 "redirect_uris" => ["https://other.test/callback"]
               })
    end

    test "records oauth_client.created with the client_id and the URIs" do
      user = insert_verified_user()

      {:ok, client} =
        OAuth.create_client(user.id, %{"name" => "N", "redirect_uris" => ["https://n.test/c"]})

      assert [event] =
               user.id
               |> Audit.list_recent_for_user(20)
               |> Enum.filter(&(&1.action == "oauth_client.created"))

      assert event.resource_type == "oauth_client"
      assert event.resource_id == client.id
      assert event.metadata["client_id"] == client.client_id
      assert event.metadata["redirect_uris"] == ["https://n.test/c"]
    end

    test "a rejected registration leaves no trail" do
      user = insert_verified_user()

      assert {:error, _} = OAuth.create_client(user.id, %{"name" => "N"})

      assert user.id
             |> Audit.list_recent_for_user(20)
             |> Enum.filter(&(&1.action == "oauth_client.created")) == []
    end
  end

  describe "update_client/3" do
    test "renames and re-derives the origin keys" do
      client = insert_oauth_client(redirect_uris: ["https://old.test/c"])

      {:ok, updated} =
        OAuth.update_client(client, %{
          "name" => "New",
          "redirect_uris" => ["https://new.test/c"]
        })

      assert updated.name == "New"
      assert updated.origin_keys == ["https://new.test"]
      assert updated.client_id == client.client_id
    end

    test "cannot publish itself or change owner" do
      other = insert_verified_user()
      client = insert_oauth_client()

      {:ok, updated} =
        OAuth.update_client(client, %{"published" => true, "user_id" => other.id})

      refute updated.published
      assert updated.user_id == client.user_id
    end

    test "cannot change owner with atom-keyed attributes either" do
      other = insert_verified_user()
      client = insert_oauth_client()

      {:ok, updated} = OAuth.update_client(client, %{user_id: other.id, name: "Renamed"})

      assert updated.user_id == client.user_id
      assert updated.name == "Renamed"
    end

    test "cannot change an operator-published registration" do
      client = insert_oauth_client(published: true)

      assert {:error, changeset} = OAuth.update_client(client, %{name: "Renamed"})
      assert "published clients can only be changed by an operator" in errors_on(changeset).base
      assert OAuth.get_client_record(client.id, client.user_id).name == client.name
    end

    test "names the fields that changed" do
      client = insert_oauth_client(name: "Before")

      {:ok, _} = OAuth.update_client(client, %{"name" => "After"})

      assert [event] =
               client.user_id
               |> Audit.list_recent_for_user(20)
               |> Enum.filter(&(&1.action == "oauth_client.updated"))

      assert event.metadata["changed"] == ["name"]
    end

    # ADR 0013: only record what happened. A PATCH with the same values is a
    # legal request (no field of OAuthClientUpdateRequest is required), and an
    # `oauth_client.updated` row whose `changed` list is empty is worse than
    # no row.
    test "an update that moves nothing succeeds and leaves no trail" do
      client = insert_oauth_client(name: "Same")

      assert {:ok, same} =
               OAuth.update_client(client, %{
                 "name" => "Same",
                 "redirect_uris" => client.redirect_uris
               })

      assert same.id == client.id
      assert same.name == "Same"

      assert client.user_id
             |> Audit.list_recent_for_user(20)
             |> Enum.filter(&(&1.action == "oauth_client.updated")) == []
    end

    test "an empty change set is a no-op too" do
      client = insert_oauth_client()

      assert {:ok, _} = OAuth.update_client(client, %{})

      assert client.user_id
             |> Audit.list_recent_for_user(20)
             |> Enum.filter(&(&1.action == "oauth_client.updated")) == []
    end

    test "a refused update leaves no trail" do
      client = insert_oauth_client(published: true)

      assert {:error, _} = OAuth.update_client(client, %{"name" => "Renamed"})

      assert client.user_id
             |> Audit.list_recent_for_user(20)
             |> Enum.filter(&(&1.action == "oauth_client.updated")) == []
    end
  end

  describe "delete_client/2" do
    test "removes the row and records it" do
      client = insert_oauth_client()

      {:ok, _} = OAuth.delete_client(client)

      assert OAuth.list_clients(client.user_id) == []

      assert [event] =
               client.user_id
               |> Audit.list_recent_for_user(20)
               |> Enum.filter(&(&1.action == "oauth_client.deleted"))

      assert event.metadata["client_id"] == client.client_id
    end

    test "cannot remove an operator-published registration" do
      client = insert_oauth_client(published: true)

      assert {:error, changeset} = OAuth.delete_client(client)
      assert "published clients can only be removed by an operator" in errors_on(changeset).base
      assert OAuth.get_client_record(client.id, client.user_id)
    end
  end

  describe "list_clients/1 and get_client_record/2" do
    test "are scoped to the tenant" do
      mine = insert_oauth_client()
      theirs = insert_oauth_client()

      assert [found] = OAuth.list_clients(mine.user_id)
      assert found.id == mine.id

      assert OAuth.get_client_record(mine.id, mine.user_id)
      refute OAuth.get_client_record(theirs.id, mine.user_id)
    end

    test "get_client_record/2 returns nil for an id that is not a UUID" do
      client = insert_oauth_client()

      refute OAuth.get_client_record("foo", client.user_id)
      refute OAuth.get_client_record("", client.user_id)
    end

    test "lists every client the account holds" do
      user = insert_verified_user()
      one = insert_oauth_client(user_id: user.id, name: "One")
      two = insert_oauth_client(user_id: user.id, name: "Two")

      assert user.id |> OAuth.list_clients() |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([one.id, two.id])
    end

    # Timestamps are second-precision, so these two almost certainly share one.
    # Without the id tie-break the order here is the planner's choice.
    test "orders deterministically when two land in the same second" do
      user = insert_verified_user()
      for n <- 1..5, do: insert_oauth_client(user_id: user.id, name: "App #{n}")

      ids = user.id |> OAuth.list_clients() |> Enum.map(& &1.id)

      expected =
        user.id
        |> OAuth.list_clients()
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at), &1.id}, :desc)
        |> Enum.map(& &1.id)

      assert ids == expected
    end
  end
end
