defmodule Fountain.Agents.AgentTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents.Agent

  @valid_attrs %{
    name: "My Agent",
    model: "anthropic/claude-3-5-sonnet",
    runtime: "claude"
  }

  describe "runtimes/0" do
    test "returns the expected list of runtimes" do
      assert Agent.runtimes() == ~w(claude codex gemini opencode)
    end
  end

  describe "changeset/2 — required fields" do
    test "valid attrs produce a valid changeset" do
      changeset = Agent.changeset(%Agent{}, @valid_attrs)
      assert changeset.valid?
    end

    test "missing :name produces an error" do
      changeset = Agent.changeset(%Agent{}, Map.delete(@valid_attrs, :name))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "missing :model produces an error" do
      changeset = Agent.changeset(%Agent{}, Map.delete(@valid_attrs, :model))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).model
    end

    test "missing :runtime produces an error" do
      changeset = Agent.changeset(%Agent{}, Map.delete(@valid_attrs, :runtime))
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).runtime
    end
  end

  describe "changeset/2 — runtime inclusion" do
    for runtime <- ~w(claude codex gemini opencode) do
      test "runtime #{runtime} is valid" do
        changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :runtime, unquote(runtime)))
        assert changeset.valid?
      end
    end

    test "invalid runtime produces an error" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :runtime, "unknown"))
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).runtime
    end
  end

  describe "changeset/2 — model format" do
    test "provider/model_id with hyphen passes" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "anthropic/claude-3-5"))
      assert changeset.valid?
    end

    test "provider/model_id with dots passes" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "anthropic/claude-3.5-sonnet"))
      assert changeset.valid?
    end

    test "model without slash fails" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "invalid"))
      refute changeset.valid?
      assert "must be in canonical provider/model_id form" in errors_on(changeset).model
    end

    test "model with uppercase letters fails" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "UPPER/Model"))
      refute changeset.valid?
      assert "must be in canonical provider/model_id form" in errors_on(changeset).model
    end
  end

  describe "changeset/2 — name length" do
    test "name of 1 character passes" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, "A"))
      assert changeset.valid?
    end

    test "name of 200 characters passes" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, String.duplicate("a", 200)))
      assert changeset.valid?
    end

    test "empty string name fails" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, ""))
      refute changeset.valid?
      assert errors_on(changeset).name != []
    end

    test "name of 201 characters fails" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, String.duplicate("a", 201)))
      refute changeset.valid?
      assert errors_on(changeset).name != []
    end
  end

  describe "changeset/2 — skills validation" do
    test "valid inline skill with name and content passes" do
      skills = [%{"name" => "foo", "content" => "some content"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      assert changeset.valid?
    end

    test "valid github skill with source passes" do
      skills = [%{"source" => "owner/repo"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      assert changeset.valid?
    end

    test "skill with both content and source fails" do
      skills = [%{"name" => "foo", "content" => "x", "source" => "o/r"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).skills, &String.contains?(&1, "only one of"))
    end

    test "skill with neither content nor source fails" do
      skills = [%{}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).skills, &String.contains?(&1, "must set content"))
    end

    test "inline skill missing name fails" do
      skills = [%{"content" => "x"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).skills, &String.contains?(&1, "inline skills require a name"))
    end

    test "non-map skill entry fails" do
      # Ecto rejects non-map entries during cast ({:array, :map}), before
      # validate_skills runs, so the error is "is invalid" on the :skills field.
      skills = ["not-a-map"]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?
      assert errors_on(changeset).skills != []
    end
  end
end
