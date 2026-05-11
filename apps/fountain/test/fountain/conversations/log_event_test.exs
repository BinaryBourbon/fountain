defmodule Fountain.Conversations.LogEventTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.LogEvent

  defp valid_attrs do
    %{
      kind: "output",
      conversation_id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp changeset(overrides \\ %{}) do
    LogEvent.changeset(%LogEvent{}, Map.merge(valid_attrs(), overrides))
  end

  describe "kinds/0" do
    test "returns all valid kinds" do
      assert LogEvent.kinds() == ~w(output stage)
    end
  end

  describe "streams/0" do
    test "returns all valid streams" do
      assert LogEvent.streams() == ~w(stdout stderr)
    end
  end

  describe "states/0" do
    test "returns all valid states" do
      assert LogEvent.states() == ~w(started done failed interrupted)
    end
  end

  describe "struct defaults" do
    test "stream defaults to empty string" do
      assert %LogEvent{}.stream == ""
    end

    test "data defaults to empty string" do
      assert %LogEvent{}.data == ""
    end

    test "stage defaults to empty string" do
      assert %LogEvent{}.stage == ""
    end

    test "state defaults to empty string" do
      assert %LogEvent{}.state == ""
    end
  end

  describe "changeset/2 with valid attrs" do
    test "is valid with kind, conversation_id, and inserted_at" do
      assert changeset().valid?
    end
  end

  describe "changeset/2 required fields" do
    test "errors when kind is missing" do
      errors = changeset(%{kind: nil}) |> errors_on()
      assert "can't be blank" in errors.kind
    end

    test "errors when conversation_id is missing" do
      errors = changeset(%{conversation_id: nil}) |> errors_on()
      assert "can't be blank" in errors.conversation_id
    end

    test "errors when inserted_at is missing" do
      errors = changeset(%{inserted_at: nil}) |> errors_on()
      assert "can't be blank" in errors.inserted_at
    end
  end

  describe "changeset/2 kind inclusion" do
    for kind <- ~w(output stage) do
      test "accepts kind '#{kind}'" do
        assert changeset(%{kind: unquote(kind)}).valid?
      end
    end

    test "rejects an unknown kind" do
      errors = changeset(%{kind: "unknown"}) |> errors_on()
      assert "is invalid" in errors.kind
    end
  end

  describe "changeset/2 stream inclusion" do
    for stream <- ["stdout", "stderr", ""] do
      test "accepts stream #{inspect(stream)}" do
        assert changeset(%{stream: unquote(stream)}).valid?
      end
    end

    test "rejects an invalid stream" do
      errors = changeset(%{stream: "stdin"}) |> errors_on()
      assert "is invalid" in errors.stream
    end
  end

  describe "changeset/2 state inclusion" do
    for state <- ["started", "done", "failed", "interrupted", ""] do
      test "accepts state #{inspect(state)}" do
        assert changeset(%{state: unquote(state)}).valid?
      end
    end

    test "rejects an invalid state" do
      errors = changeset(%{state: "unknown"}) |> errors_on()
      assert "is invalid" in errors.state
    end
  end
end
