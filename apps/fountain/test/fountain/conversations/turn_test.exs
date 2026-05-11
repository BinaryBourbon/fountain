defmodule Fountain.Conversations.TurnTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Turn

  defp valid_attrs do
    %{
      turn_number: 1,
      prompt: "Hello",
      status: "pending",
      conversation_id: Ecto.UUID.generate()
    }
  end

  defp changeset(overrides \\ %{}) do
    Turn.changeset(%Turn{}, Map.merge(valid_attrs(), overrides))
  end

  describe "statuses/0" do
    test "returns all five valid statuses" do
      assert Turn.statuses() == ~w(pending running completed failed interrupted)
    end
  end

  describe "struct defaults" do
    test "default status is 'pending'" do
      assert %Turn{}.status == "pending"
    end
  end

  describe "changeset/2 with valid attrs" do
    test "is valid with all required fields" do
      assert changeset().valid?
    end
  end

  describe "changeset/2 required fields" do
    test "errors when turn_number is missing" do
      errors = changeset(%{turn_number: nil}) |> errors_on()
      assert "can't be blank" in errors.turn_number
    end

    test "errors when prompt is missing" do
      errors = changeset(%{prompt: nil}) |> errors_on()
      assert "can't be blank" in errors.prompt
    end

    test "errors when status is missing (nil)" do
      errors = changeset(%{status: nil}) |> errors_on()
      assert "can't be blank" in errors.status
    end

    test "errors when conversation_id is missing" do
      errors = changeset(%{conversation_id: nil}) |> errors_on()
      assert "can't be blank" in errors.conversation_id
    end
  end

  describe "changeset/2 status inclusion" do
    for status <- ~w(pending running completed failed interrupted) do
      test "accepts status '#{status}'" do
        assert changeset(%{status: unquote(status)}).valid?
      end
    end

    test "rejects an unknown status" do
      errors = changeset(%{status: "unknown"}) |> errors_on()
      assert "is invalid" in errors.status
    end
  end
end
