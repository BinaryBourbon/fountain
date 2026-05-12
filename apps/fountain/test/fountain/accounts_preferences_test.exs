defmodule Fountain.AccountsPreferencesTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.User

  describe "User.preferences_changeset/2" do
    test "accepts valid conversations_roots_only values" do
      for val <- [true, false] do
        cs = User.preferences_changeset(%User{}, %{conversations_roots_only: val})
        assert cs.valid?, "expected #{inspect(val)} to be valid"
      end
    end

    test "accepts valid conversation_visible_streams subsets" do
      for streams <- [[], ["stdout"], ["stderr"], ["stage"], ["stdout", "stderr"], ["stdout", "stderr", "stage"]] do
        cs = User.preferences_changeset(%User{}, %{conversation_visible_streams: streams})
        assert cs.valid?, "expected #{inspect(streams)} to be valid"
      end
    end

    test "rejects invalid stream values" do
      cs = User.preferences_changeset(%User{}, %{conversation_visible_streams: ["stdout", "invalid"]})
      refute cs.valid?
      assert cs.errors[:conversation_visible_streams] != nil
    end

    test "accepts partial updates (only roots_only)" do
      cs = User.preferences_changeset(%User{}, %{conversations_roots_only: true})
      assert cs.valid?
    end

    test "accepts partial updates (only visible_streams)" do
      cs = User.preferences_changeset(%User{}, %{conversation_visible_streams: ["stdout"]})
      assert cs.valid?
    end
  end

  describe "Accounts.update_preferences/2" do
    setup do
      {:ok, user: insert_verified_user()}
    end

    test "persists conversations_roots_only", %{user: user} do
      assert {:ok, updated} = Accounts.update_preferences(user, %{conversations_roots_only: true})
      assert updated.conversations_roots_only == true

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.conversations_roots_only == true
    end

    test "persists conversation_visible_streams", %{user: user} do
      streams = ["stdout", "stage"]
      assert {:ok, updated} = Accounts.update_preferences(user, %{conversation_visible_streams: streams})
      assert updated.conversation_visible_streams == streams

      reloaded = Accounts.get_user!(user.id)
      assert reloaded.conversation_visible_streams == streams
    end

    test "persists empty visible_streams list", %{user: user} do
      assert {:ok, updated} = Accounts.update_preferences(user, %{conversation_visible_streams: []})
      assert updated.conversation_visible_streams == []
    end

    test "returns error changeset for invalid streams", %{user: user} do
      assert {:error, changeset} = Accounts.update_preferences(user, %{conversation_visible_streams: ["bad"]})
      assert changeset.errors[:conversation_visible_streams] != nil
    end

    test "new users default to roots_only false and all streams", %{user: user} do
      assert user.conversations_roots_only == false
      assert user.conversation_visible_streams == ["stdout", "stderr", "stage"]
    end
  end
end
