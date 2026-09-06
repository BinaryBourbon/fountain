defmodule Fountain.PermissionPolicyTest do
  @moduledoc """
  The Fountain half of a permission policy (#1635): the one key that names no
  tool, and keeping it away from the library that reads every key as one.
  """

  use ExUnit.Case, async: true

  alias Fountain.PermissionPolicy

  describe "verdicts/1" do
    test "hands the library the tool half and nothing else" do
      policy = %{"default" => "ask", "execute" => "auto_deny", "ask_timeout" => 86_400}

      assert PermissionPolicy.verdicts(policy) == %{
               "default" => "ask",
               "execute" => "auto_deny"
             }
    end

    test "a reserved key left in would come back as a verdict" do
      # This is why the stripping exists rather than being tidiness:
      # `verdict_for/2` reads an unrecognised value as auto_deny, and
      # `effective/2` writes that reading back into the merged map, so a
      # policy round-tripped through the library would grow
      # `"ask_timeout" => "auto_deny"`.
      merged = Managoat.ACP.Permissions.effective(%{"ask_timeout" => 600}, %{})
      assert merged["ask_timeout"] == "auto_deny"

      stripped =
        Managoat.ACP.Permissions.effective(
          PermissionPolicy.verdicts(%{"ask_timeout" => 600}),
          %{}
        )

      refute Map.has_key?(stripped, "ask_timeout")
    end

    test "a policy that is not a map is an empty one" do
      assert PermissionPolicy.verdicts(nil) == %{}
      assert PermissionPolicy.verdicts("nope") == %{}
    end
  end

  describe "ask_timeout_seconds/1" do
    test "reads a positive integer or a string of one" do
      assert PermissionPolicy.ask_timeout_seconds(%{"ask_timeout" => 3600}) == 3600
      assert PermissionPolicy.ask_timeout_seconds(%{"ask_timeout" => "3600"}) == 3600
    end

    test "anything else is nil, so the caller falls back rather than denying at once" do
      for value <- [0, -1, "", "soon", "60s", 1.5, nil, %{}] do
        assert PermissionPolicy.ask_timeout_seconds(%{"ask_timeout" => value}) == nil
      end

      assert PermissionPolicy.ask_timeout_seconds(%{}) == nil
      assert PermissionPolicy.ask_timeout_seconds(nil) == nil
    end
  end

  describe "effective_ask_timeout_seconds/2 and check_narrows/2" do
    test "the smaller of the two wins, because a shorter wait withholds more" do
      assert PermissionPolicy.effective_ask_timeout_seconds(
               %{"ask_timeout" => 86_400},
               %{"ask_timeout" => 600}
             ) == 600
    end

    test "either side alone is honoured, and neither leaves nil" do
      assert PermissionPolicy.effective_ask_timeout_seconds(%{"ask_timeout" => 60}, %{}) == 60
      assert PermissionPolicy.effective_ask_timeout_seconds(%{}, %{"ask_timeout" => 60}) == 60
      assert PermissionPolicy.effective_ask_timeout_seconds(%{}, %{}) == nil
    end

    test "a launch may shorten the wait and may not lengthen it" do
      assert PermissionPolicy.check_narrows(%{"ask_timeout" => 600}, %{"ask_timeout" => 60}) ==
               :ok

      assert PermissionPolicy.check_narrows(%{"ask_timeout" => 60}, %{"ask_timeout" => 600}) ==
               {:error, {:permission_policy_widens, "ask_timeout"}}
    end

    test "with no agent value, the ceiling the host passes is what a launch may not exceed" do
      # A longer wait is more time for the tool to be approved, so longer is
      # looser. Without the ceiling an agent that never set the key would let
      # any launch buy days, which is the escalation the rule exists to stop.
      assert PermissionPolicy.check_narrows(%{}, %{"ask_timeout" => 60}, 300) == :ok

      assert PermissionPolicy.check_narrows(%{}, %{"ask_timeout" => 86_400}, 300) ==
               {:error, {:permission_policy_widens, "ask_timeout"}}
    end

    test "the agent's own value outranks the ceiling, in both directions" do
      assert PermissionPolicy.check_narrows(
               %{"ask_timeout" => 86_400},
               %{"ask_timeout" => 3600},
               300
             ) == :ok

      assert PermissionPolicy.check_narrows(%{"ask_timeout" => 60}, %{"ask_timeout" => 120}, 300) ==
               {:error, {:permission_policy_widens, "ask_timeout"}}
    end

    test "a launch that names none is never a widening" do
      assert PermissionPolicy.check_narrows(%{"ask_timeout" => 60}, %{}, 300) == :ok
      assert PermissionPolicy.check_narrows(%{}, %{}, 300) == :ok
    end
  end

  describe "keep_reserved/2" do
    test "a form that rebuilds the tool half does not drop the rest" do
      rebuilt = %{"default" => "ask"}
      stored = %{"default" => "auto_allow", "ask_timeout" => 7200}

      assert PermissionPolicy.keep_reserved(rebuilt, stored) == %{
               "default" => "ask",
               "ask_timeout" => 7200
             }
    end

    test "nothing to keep leaves the policy alone" do
      assert PermissionPolicy.keep_reserved(%{"default" => "ask"}, nil) == %{"default" => "ask"}
      assert PermissionPolicy.keep_reserved(%{}, %{"execute" => "ask"}) == %{}
    end
  end
end
