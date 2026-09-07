defmodule Fountain.Conversations.ExecutionLimitsTest do
  use ExUnit.Case, async: true
  alias Fountain.Conversations.ExecutionLimits, as: Limits

  test "omission inherits every host and account ceiling" do
    for request <- [nil, %{}] do
      assert {:ok, %{"wall_time_seconds" => 60, "max_model_turns" => 10}} =
               Limits.resolve(%{"wall_time_seconds" => 60}, %{max_model_turns: 10}, request)
    end
  end

  test "the smaller configured ceiling wins independently for each field" do
    assert {:ok, %{"wall_time_seconds" => 20, "max_model_turns" => 5}} =
             Limits.resolve(
               %{wall_time_seconds: 20, max_model_turns: 10},
               %{wall_time_seconds: 30, max_model_turns: 5},
               nil
             )
  end

  test "a partial request narrows one field and retains all other ceilings" do
    assert {:ok, %{"wall_time_seconds" => 10, "max_model_turns" => 5}} =
             Limits.resolve(%{wall_time_seconds: 20}, %{max_model_turns: 5}, %{
               wall_time_seconds: 10
             })
  end

  test "requests cannot exceed either effective ceiling" do
    for {host, account} <- [{%{max_model_turns: 5}, nil}, {nil, %{max_model_turns: 5}}] do
      assert {:error, {:execution_limits_widen, "max_model_turns"}} =
               Limits.resolve(host, account, %{max_model_turns: 6})
    end
  end

  test "no configured ceiling still permits a valid voluntarily bounded request" do
    assert {:ok, %{"wall_time_seconds" => 60}} =
             Limits.resolve(nil, nil, %{wall_time_seconds: 60})

    assert {:ok, %{}} = Limits.resolve(nil, nil, nil)
  end

  test "explicit nulls cannot disable inherited controls" do
    for field <- Limits.keys() do
      assert {:error, {:execution_limits_invalid, ^field}} =
               Limits.resolve(%{field => 5}, nil, %{field => nil})
    end
  end

  test "unknown fields, arbitrary metadata and nonobjects are refused" do
    for request <- [
          %{"maxTurns" => 5},
          %{"_meta" => %{}},
          %{"options" => %{}},
          3,
          false,
          [],
          "10"
        ] do
      assert {:error, {:execution_limits_invalid, _}} = Limits.normalize(request)
    end
  end

  test "duplicate atom/string keys cannot pick a value by enumeration order" do
    assert {:error, {:execution_limits_invalid, "duplicate_field"}} =
             Limits.normalize(%{:max_model_turns => 2, "max_model_turns" => 200})
  end

  test "integers stay integers and dollar fractions stay numeric" do
    assert {:ok, %{"max_model_turns" => 3, "max_estimated_cost_usd" => 0.25}} =
             Limits.normalize(%{max_model_turns: 3, max_estimated_cost_usd: 0.25})

    for field <- ["max_model_turns", "wall_time_seconds"], value <- ["5", 5.0, 0, -1, true] do
      assert {:error, {:execution_limits_invalid, ^field}} = Limits.normalize(%{field => value})
    end
  end

  test "wire bounds refuse nonrepresentable deadlines and unsafe JSON integers" do
    assert {:error, _} = Limits.normalize(%{wall_time_seconds: Limits.max_wall_seconds() + 1})
    assert {:error, _} = Limits.normalize(%{max_model_turns: 9_007_199_254_740_992})
    assert {:error, _} = Limits.normalize(%{max_estimated_cost_usd: 9_007_199_254_740_992})

    for value <- [0, -0.1, "0.25", nil, false] do
      assert {:error, _} = Limits.normalize(%{max_estimated_cost_usd: value})
    end
  end

  test "loosening or removing account policy never widens an existing conversation" do
    launch = %{"wall_time_seconds" => 20, "max_model_turns" => 5}
    assert {:ok, ^launch} = Limits.for_new_turn(nil, %{wall_time_seconds: 200}, launch)
    assert {:ok, ^launch} = Limits.for_new_turn(nil, nil, launch)
  end

  test "new turns inherit tightened ceilings without losing other saved limits" do
    assert {:ok, %{"wall_time_seconds" => 10, "max_model_turns" => 5}} =
             Limits.for_new_turn(nil, %{wall_time_seconds: 10}, %{
               wall_time_seconds: 20,
               max_model_turns: 5
             })
  end

  test "channel resume cannot reset a narrower launch allowance" do
    assert {:error, {:execution_limits_widen, "max_model_turns"}} =
             Limits.for_resume(nil, %{max_model_turns: 100}, %{max_model_turns: 5}, %{
               max_model_turns: 10
             })

    assert {:ok, %{"max_model_turns" => 5}} =
             Limits.for_resume(nil, nil, %{max_model_turns: 5}, nil)
  end

  test "malformed host or saved policy fails closed instead of dropping a ceiling" do
    for {host, account, saved} <- [
          {%{wall_time_seconds: "60"}, nil, nil},
          {nil, %{max_model_turns: 0}, nil},
          {nil, nil, %{wall_time_seconds: nil}}
        ] do
      assert {:error, {:execution_limits_invalid, _}} = Limits.for_new_turn(host, account, saved)
    end
  end

  test "runtime capability checks cover inherited controls as well as requested ones" do
    {:ok, limits} = Limits.resolve(%{wall_time_seconds: 60}, nil, %{max_model_turns: 3})

    assert {:error, {:execution_limits_unsupported, ["wall_time_seconds"]}} =
             Limits.require_controls(limits, ["max_model_turns"])

    assert :ok = Limits.require_controls(limits, ["wall_time_seconds", "max_model_turns"])
    assert :ok = Limits.require_controls(%{}, [])
  end

  test "host JSON configuration validates its shape instead of disabling malformed limits" do
    assert {:ok, %{}} = Limits.from_json_env(nil)

    assert {:ok, %{"wall_time_seconds" => 60}} =
             Limits.from_json_env(~s({"wall_time_seconds":60}))

    for value <- [
          "null",
          "[]",
          "not-json",
          ~s({"wall_time_seconds":null}),
          ~s({"secret":"never echo me"})
        ] do
      assert {:error, {:execution_limits_invalid, reason}} = Limits.from_json_env(value)
      refute reason =~ "never echo me"
    end
  end

  test "SDK options contain only adapter fields and never the host deadline" do
    assert %{max_model_turns: 3, max_estimated_cost_usd: 0.25} =
             Limits.sdk_options(%{
               "wall_time_seconds" => 60,
               "max_model_turns" => 3,
               "max_estimated_cost_usd" => 0.25
             })

    assert nil == Limits.sdk_options(%{"wall_time_seconds" => 60})
  end
end
