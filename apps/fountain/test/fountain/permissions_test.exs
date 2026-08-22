defmodule Fountain.PermissionsTest do
  use ExUnit.Case, async: true

  alias Fountain.Permissions

  defp req(options, tool \\ nil) do
    params = %{"options" => options}
    if tool, do: Map.put(params, "toolCall", %{"title" => tool}), else: params
  end

  defp allow_always, do: %{"optionId" => "aa", "kind" => "allow_always"}
  defp allow_once, do: %{"optionId" => "ao", "kind" => "allow_once"}
  defp reject_once, do: %{"optionId" => "ro", "kind" => "reject_once"}
  defp reject_always, do: %{"optionId" => "ra", "kind" => "reject_always"}

  describe "auto_allow is parity with the pre-#939 constant" do
    test "prefers allow_always, then allow_once" do
      assert %{outcome: "selected", optionId: "aa"} =
               Permissions.outcome(%{}, req([reject_once(), allow_once(), allow_always()]))

      assert %{outcome: "selected", optionId: "ao"} =
               Permissions.outcome(%{}, req([reject_once(), allow_once()]))
    end

    test "falls back to the first option offered, whatever its kind" do
      # The rung that makes this parity rather than a new behaviour: the old
      # ladder ended in `List.first(options)`. An adapter offering only bespoke
      # kinds must still be answered exactly as it was before.
      assert %{outcome: "selected", optionId: "weird"} =
               Permissions.outcome(%{}, req([%{"optionId" => "weird", "kind" => "custom"}]))
    end

    test "cancels only when nothing at all was offered" do
      assert %{outcome: "cancelled"} = Permissions.outcome(%{}, req([]))
    end

    test "a nil policy behaves like an empty one" do
      assert %{outcome: "selected", optionId: "aa"} =
               Permissions.outcome(nil, req([allow_always()]))
    end
  end

  describe "auto_deny never synthesises an option" do
    @deny %{"default" => "auto_deny"}

    test "prefers reject_always, then reject_once" do
      assert %{outcome: "selected", optionId: "ra"} =
               Permissions.outcome(@deny, req([reject_once(), reject_always()]))

      assert %{outcome: "selected", optionId: "ro"} =
               Permissions.outcome(@deny, req([allow_always(), reject_once()]))
    end

    test "cancels rather than picking the first option when no rejection is offered" do
      # The deny path has no first-option rung on purpose. Falling back to
      # "whatever was offered first" would select an *allow* here, which is the
      # one thing auto_deny must never do.
      assert %{outcome: "cancelled"} =
               Permissions.outcome(@deny, req([allow_always(), allow_once()]))
    end
  end

  describe "verdict_for" do
    test "tool entry beats the default" do
      policy = %{"default" => "auto_allow", "Bash" => "auto_deny"}
      assert Permissions.verdict_for(policy, "Bash") == "auto_deny"
      assert Permissions.verdict_for(policy, "Read") == "auto_allow"
    end

    test "an unset default is auto_allow" do
      assert Permissions.verdict_for(%{}, "Bash") == "auto_allow"
      assert Permissions.verdict_for(%{"Read" => "auto_deny"}, "Bash") == "auto_allow"
    end

    test "a value that is not a verdict denies rather than allowing" do
      # The changesets reject these, so reaching here means the row was written
      # around them. Failing closed is the only safe reading.
      assert Permissions.verdict_for(%{"Bash" => "banana"}, "Bash") == "auto_deny"
      assert Permissions.verdict_for(%{"default" => nil, "Bash" => 7}, "Bash") == "auto_deny"
    end
  end

  describe "effective/2 clamps to the stricter side" do
    test "the launch may tighten a tool" do
      effective = Permissions.effective(%{"default" => "auto_allow"}, %{"Bash" => "auto_deny"})
      assert Permissions.verdict_for(effective, "Bash") == "auto_deny"
      assert Permissions.verdict_for(effective, "Read") == "auto_allow"
    end

    test "the launch cannot loosen a tool, even if the row says so" do
      # This is the invariant the peer depends on: whatever is stored, the merge
      # can never produce something looser than the agent's own policy.
      effective = Permissions.effective(%{"Bash" => "auto_deny"}, %{"Bash" => "auto_allow"})
      assert Permissions.verdict_for(effective, "Bash") == "auto_deny"
    end

    test "the launch cannot loosen via the default either" do
      effective = Permissions.effective(%{"default" => "auto_deny"}, %{"default" => "auto_allow"})
      assert Permissions.verdict_for(effective, "anything") == "auto_deny"
    end

    test "a tool covered only by the agent's default is still clamped" do
      # The launch names Bash explicitly; the agent covers it by default. The
      # merge has to compare effective verdicts, not just the key sets.
      effective = Permissions.effective(%{"default" => "auto_deny"}, %{"Bash" => "auto_allow"})
      assert Permissions.verdict_for(effective, "Bash") == "auto_deny"
    end

    test "nil on either side is an empty policy" do
      assert Permissions.verdict_for(Permissions.effective(nil, nil), "Bash") == "auto_allow"

      assert Permissions.verdict_for(Permissions.effective(nil, %{"Bash" => "auto_deny"}), "Bash") ==
               "auto_deny"
    end
  end

  describe "check_narrows/2" do
    test "narrowing is allowed" do
      assert :ok =
               Permissions.check_narrows(%{"default" => "auto_allow"}, %{"Bash" => "auto_deny"})

      assert :ok = Permissions.check_narrows(%{}, %{"default" => "auto_deny"})
      assert :ok = Permissions.check_narrows(nil, nil)
    end

    test "an equal policy is allowed" do
      assert :ok = Permissions.check_narrows(%{"Bash" => "auto_deny"}, %{"Bash" => "auto_deny"})
    end

    test "widening a named tool is refused, and names it" do
      assert {:error, {:permission_policy_widens, "Bash"}} =
               Permissions.check_narrows(%{"Bash" => "auto_deny"}, %{"Bash" => "auto_allow"})
    end

    test "widening the default is refused" do
      assert {:error, {:permission_policy_widens, "default"}} =
               Permissions.check_narrows(%{"default" => "auto_deny"}, %{"default" => "auto_allow"})
    end

    test "widening a tool the agent covered only by its default is refused" do
      # The launch names a tool the agent never did. Comparing key sets alone
      # would miss this: the agent's default is what covers Bash.
      assert {:error, {:permission_policy_widens, "Bash"}} =
               Permissions.check_narrows(%{"default" => "auto_deny"}, %{"Bash" => "auto_allow"})
    end

    test "a launch lowering only the default still loosens the agent's tools" do
      assert {:error, {:permission_policy_widens, _}} =
               Permissions.check_narrows(
                 %{"default" => "auto_deny", "Read" => "auto_deny"},
                 %{"default" => "auto_allow"}
               )
    end
  end

  describe "tool_name/1" do
    test "prefers the agent's title, falls back to ACP's kind" do
      assert Permissions.tool_name(%{"toolCall" => %{"title" => "Bash", "kind" => "execute"}}) ==
               "Bash"

      assert Permissions.tool_name(%{"toolCall" => %{"kind" => "execute"}}) == "execute"
      assert Permissions.tool_name(%{"toolCall" => %{"title" => ""}}) == nil
    end

    test "a request with no tool call falls through to the default" do
      assert Permissions.tool_name(%{"options" => []}) == nil

      assert Permissions.outcome(%{"default" => "auto_deny"}, req([reject_once()])) ==
               %{outcome: "selected", optionId: "ro"}
    end
  end

  describe "ask" do
    test "is buildable since #940 gave it somewhere to ask" do
      assert "ask" in Permissions.verdicts()
      assert Permissions.buildable?("ask")
      assert Permissions.buildable?("auto_allow")
      assert Permissions.buildable?("auto_deny")
    end

    test "outcome/2 denies rather than allows, for a caller that asks anyway" do
      # The peer does not route `ask` through outcome/2 — it holds the request
      # open instead — but the safe reading is written down rather than assumed.
      assert %{outcome: "selected", optionId: "ro"} =
               Permissions.outcome(%{"default" => "ask"}, req([allow_always(), reject_once()]))
    end

    test "the timeout sits under the idle bound, or an unanswered prompt costs the disk" do
      # Lifecycle.check/4 suppresses only the idle verdict while a turn is in
      # flight, and per 0017 the idle bound suspends while the ceiling
      # destroys. A timeout at or above the idle bound would mean an
      # unanswered prompt is resolved by the ceiling instead — burning the
      # whole lifetime and taking the agent's memory with it (#649).
      assert Permissions.ask_timeout_ms() <
               Fountain.Conversations.Lifecycle.idle_timeout_seconds() * 1000
    end

    test "is stricter than allow and looser than deny" do
      assert Permissions.stricter("auto_allow", "ask") == "ask"
      assert Permissions.stricter("ask", "auto_deny") == "auto_deny"
    end
  end
end
