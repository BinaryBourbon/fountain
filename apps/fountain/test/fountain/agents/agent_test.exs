defmodule Fountain.Agents.AgentTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents.Agent

  @valid_attrs %{
    name: "My Agent",
    model: "anthropic/claude-3-5-sonnet",
    runtime: "claude"
  }

  # A model whose provider prefix each runtime actually accepts. opencode is
  # multi-provider, so any prefix is fine there.
  @model_for %{
    "claude" => "anthropic/claude-sonnet-4-6",
    "codex" => "openai/gpt-5-codex",
    "gemini" => "google/gemini-2.5-pro",
    "opencode" => "anthropic/claude-sonnet-4-6"
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
        attrs =
          Map.merge(@valid_attrs, %{
            runtime: unquote(runtime),
            model: @model_for[unquote(runtime)]
          })

        changeset = Agent.changeset(%Agent{}, attrs)
        assert changeset.valid?
      end
    end

    test "invalid runtime produces an error" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :runtime, "unknown"))
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).runtime
    end
  end

  describe "changeset/2 — model provider matches runtime" do
    # #553: these three runtimes pass the bare model id to their CLI, so a
    # mismatched prefix would ship e.g. `gpt-5` to `claude --model`.
    test "claude rejects a non-anthropic model" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "openai/gpt-5"))
      refute changeset.valid?
      assert "claude runtime requires a anthropic/ model" in errors_on(changeset).model
    end

    test "codex rejects a non-openai model" do
      attrs = Map.merge(@valid_attrs, %{runtime: "codex", model: "anthropic/claude-sonnet-4-6"})
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "codex runtime requires a openai/ model" in errors_on(changeset).model
    end

    test "gemini rejects a non-google model" do
      attrs = Map.merge(@valid_attrs, %{runtime: "gemini", model: "openai/gpt-5"})
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?
      assert "gemini runtime requires a google/ model" in errors_on(changeset).model
    end

    test "opencode accepts any known provider — it is the multi-provider runtime" do
      for model <- ~w(anthropic/claude-sonnet-4-6 openai/gpt-5 google/gemini-2.5-pro) do
        attrs = Map.merge(@valid_attrs, %{runtime: "opencode", model: model})
        assert Agent.changeset(%Agent{}, attrs).valid?
      end
    end

    # #554: opencode reads the prefix to pick which API key to export and
    # falls through to none for an unrecognised one, so a typo used to reach
    # the sprite with no inference credentials and fail as an auth error.
    test "opencode rejects a provider Fountain holds no credentials for" do
      attrs = Map.merge(@valid_attrs, %{runtime: "opencode", model: "anthopic/claude-sonnet-4-6"})
      changeset = Agent.changeset(%Agent{}, attrs)
      refute changeset.valid?

      expected = ~s(unknown provider "anthopic" — must be one of: anthropic, openai, google)
      assert expected in errors_on(changeset).model
    end

    test "a single-provider runtime reports the runtime mismatch, not the unknown provider" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "anthopic/claude"))
      refute changeset.valid?
      assert errors_on(changeset).model == ["claude runtime requires a anthropic/ model"]
    end

    # The model id is deliberately unchecked: a model released after this
    # deploy has to be usable the day it ships.
    test "an unrecognised model id under a known provider is accepted" do
      changeset =
        Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "anthropic/claude-opus-99"))

      assert changeset.valid?
    end

    test "a runtime change alone is validated against the stored model" do
      agent = %Agent{name: "a", model: "anthropic/claude-sonnet-4-6", runtime: "claude"}
      changeset = Agent.changeset(agent, %{runtime: "codex"})
      refute changeset.valid?
      assert "codex runtime requires a openai/ model" in errors_on(changeset).model
    end

    test "a malformed model reports only the format error" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "claude-sonnet-4-6"))
      refute changeset.valid?
      assert errors_on(changeset).model == ["must be in canonical provider/model_id form"]
    end
  end

  describe "changeset/2 — model format" do
    test "provider/model_id with hyphen passes" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "anthropic/claude-3-5"))
      assert changeset.valid?
    end

    test "provider/model_id with dots passes" do
      changeset =
        Agent.changeset(%Agent{}, Map.put(@valid_attrs, :model, "anthropic/claude-3.5-sonnet"))

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
      changeset =
        Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, String.duplicate("a", 200)))

      assert changeset.valid?
    end

    test "empty string name fails" do
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, ""))
      refute changeset.valid?
      assert errors_on(changeset).name != []
    end

    test "name of 201 characters fails" do
      changeset =
        Agent.changeset(%Agent{}, Map.put(@valid_attrs, :name, String.duplicate("a", 201)))

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

    test "github skill pinned with a ref passes" do
      skills = [%{"source" => "owner/repo", "ref" => "v1.2.0"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      assert changeset.valid?
    end

    test "ref on an inline skill fails" do
      skills = [%{"name" => "foo", "content" => "x", "ref" => "main"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).skills,
               &String.contains?(&1, "ref only applies to github-sourced")
             )
    end

    test "ref with shell-unsafe characters fails" do
      skills = [%{"source" => "owner/repo", "ref" => "main; rm -rf /"}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).skills, &String.contains?(&1, "ref must match"))
    end

    test "non-string ref fails" do
      skills = [%{"source" => "owner/repo", "ref" => 42}]
      changeset = Agent.changeset(%Agent{}, Map.put(@valid_attrs, :skills, skills))
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).skills, &String.contains?(&1, "ref must match"))
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

      assert Enum.any?(
               errors_on(changeset).skills,
               &String.contains?(&1, "inline skills require a name")
             )
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

  describe "sandbox_provider" do
    test "nil inherits the instance default and validates clean" do
      changeset = Agent.changeset(%Agent{}, @valid_attrs)
      assert changeset.valid?
    end

    test "an unknown backend is rejected against the closed vocabulary" do
      changeset =
        Agent.changeset(%Agent{}, Map.put(@valid_attrs, :sandbox_provider, "modal"))

      refute changeset.valid?
      assert [msg] = errors_on(changeset).sandbox_provider
      assert msg =~ "must be one of"
    end

    test "a known but unconfigured backend is rejected at save time" do
      # e2b is in the vocabulary but has no adapter registered (and no
      # credentials in test), so pinning an agent to it must fail with a
      # message pointing at instance configuration, not at conversation start.
      changeset =
        Agent.changeset(%Agent{}, Map.put(@valid_attrs, :sandbox_provider, "e2b"))

      refute changeset.valid?
      assert [msg] = errors_on(changeset).sandbox_provider
      assert msg =~ "not configured"
    end
  end
end
