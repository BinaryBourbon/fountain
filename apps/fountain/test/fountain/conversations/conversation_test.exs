defmodule Fountain.Conversations.ConversationTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Conversation

  # Helpers

  defp valid_attrs do
    %{
      runtime: "claude",
      status: "pending",
      sandbox_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    }
  end

  defp changeset(overrides \\ %{}) do
    Conversation.changeset(%Conversation{}, Map.merge(valid_attrs(), overrides))
  end

  # ---------------------------------------------------------------------------
  # Default field values
  # ---------------------------------------------------------------------------

  describe "struct defaults" do
    test "default status is 'pending'" do
      assert %Conversation{}.status == "pending"
    end

    test "default source is 'api'" do
      assert %Conversation{}.source == "api"
    end
  end

  # ---------------------------------------------------------------------------
  # Module-level accessors
  # ---------------------------------------------------------------------------

  describe "statuses/0" do
    test "returns all six valid statuses" do
      assert Conversation.statuses() ==
               ~w(pending running idle completed failed terminated)
    end
  end

  describe "sources/0" do
    test "returns all three valid sources" do
      assert Conversation.sources() == ~w(ui api agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Valid changeset
  # ---------------------------------------------------------------------------

  describe "changeset/2 with valid attrs" do
    test "is valid with all required fields" do
      assert changeset().valid?
    end

    test "is valid without an explicit source (uses struct default)" do
      attrs = Map.delete(valid_attrs(), :source)
      cs = Conversation.changeset(%Conversation{}, attrs)
      assert cs.valid?
    end
  end

  # ---------------------------------------------------------------------------
  # Required fields
  # ---------------------------------------------------------------------------

  describe "changeset/2 required fields" do
    test "errors when runtime is missing" do
      errors = changeset(%{runtime: nil}) |> errors_on()
      assert "can't be blank" in errors.runtime
    end

    test "errors when status is missing" do
      errors = changeset(%{status: nil}) |> errors_on()
      assert "can't be blank" in errors.status
    end

    test "errors when sandbox_id is missing" do
      errors = changeset(%{sandbox_id: nil}) |> errors_on()
      assert "can't be blank" in errors.sandbox_id
    end

    test "errors when user_id is missing" do
      errors = changeset(%{user_id: nil}) |> errors_on()
      assert "can't be blank" in errors.user_id
    end

    test "errors on all required fields when attrs are empty" do
      # %Conversation{} has status: "pending" as a struct default, so casting
      # an empty map leaves status populated — only runtime/sandbox_id/user_id
      # are truly absent.
      cs = Conversation.changeset(%Conversation{}, %{})
      errors = errors_on(cs)
      assert Map.has_key?(errors, :runtime)
      assert Map.has_key?(errors, :sandbox_id)
      assert Map.has_key?(errors, :user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Status inclusion
  # ---------------------------------------------------------------------------

  describe "changeset/2 status inclusion" do
    for status <- ~w(pending running idle completed failed terminated) do
      test "accepts status '#{status}'" do
        assert changeset(%{status: unquote(status)}).valid?
      end
    end

    test "rejects an unknown status" do
      errors = changeset(%{status: "unknown"}) |> errors_on()
      assert "is invalid" in errors.status
    end
  end

  # ---------------------------------------------------------------------------
  # Source inclusion
  # ---------------------------------------------------------------------------

  describe "changeset/2 source inclusion" do
    for source <- ~w(ui api agent) do
      test "accepts source '#{source}'" do
        assert changeset(%{source: unquote(source)}).valid?
      end
    end

    test "rejects an invalid source" do
      errors = changeset(%{source: "invalid"}) |> errors_on()
      assert "is invalid" in errors.source
    end
  end

  # ---------------------------------------------------------------------------
  # Status transition via changeset
  # ---------------------------------------------------------------------------

  describe "changeset/2 status transition" do
    test "casts a status change from 'pending' to 'running'" do
      cs = Conversation.changeset(%Conversation{status: "pending"}, %{
        runtime: "claude",
        status: "running",
        sandbox_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :status) == "running"
    end
  end
end
