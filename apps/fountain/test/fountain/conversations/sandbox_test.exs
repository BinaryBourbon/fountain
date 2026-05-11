defmodule Fountain.Conversations.SandboxTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Sandbox

  defp valid_attrs do
    %{
      sprite_name: "sprite-abc123",
      status: "pending",
      user_id: Ecto.UUID.generate()
    }
  end

  defp changeset(overrides \\ %{}) do
    Sandbox.changeset(%Sandbox{}, Map.merge(valid_attrs(), overrides))
  end

  describe "statuses/0" do
    test "returns all five valid statuses" do
      assert Sandbox.statuses() == ~w(pending starting ready terminated failed)
    end
  end

  describe "struct defaults" do
    test "default status is 'pending'" do
      assert %Sandbox{}.status == "pending"
    end
  end

  describe "changeset/2 with valid attrs" do
    test "is valid with all required fields" do
      assert changeset().valid?
    end
  end

  describe "changeset/2 required fields" do
    test "errors when sprite_name is missing" do
      errors = changeset(%{sprite_name: nil}) |> errors_on()
      assert "can't be blank" in errors.sprite_name
    end

    test "errors when user_id is missing" do
      errors = changeset(%{user_id: nil}) |> errors_on()
      assert "can't be blank" in errors.user_id
    end
  end

  describe "changeset/2 status inclusion" do
    for status <- ~w(pending starting ready terminated failed) do
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
