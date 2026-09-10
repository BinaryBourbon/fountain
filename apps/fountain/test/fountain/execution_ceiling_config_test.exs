defmodule Fountain.ExecutionCeilingConfigTest do
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)
  @variable "FOUNTAIN_EXECUTION_LIMITS"
  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "EMAIL_DELIVERY" => "none",
    "PUBLIC_URL" => "https://fountain.example.com",
    "MASTER_SECRETS_KEY" => Base.url_encode64(<<0::256>>, padding: false)
  }

  setup do
    previous = Map.new([@variable | Map.keys(@base)], &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value), do: System.delete_env(key), else: System.put_env(key, value)
      end
    end)

    System.put_env(@base)
    :ok
  end

  test "unset, blank and empty JSON preserve an empty host ceiling" do
    for value <- [nil, "", "{}"] do
      assert read(value) == %{}
    end
  end

  test "boot reads all three typed controls" do
    assert read(~s({"wall_time_seconds":30,"max_model_turns":2,"max_estimated_cost_usd":0.25})) ==
             %{
               "wall_time_seconds" => 30,
               "max_model_turns" => 2,
               "max_estimated_cost_usd" => 0.25
             }
  end

  test "invalid host policy refuses boot without echoing input" do
    for value <- [
          "private-value",
          "null",
          "[]",
          ~s({"private-field":"private-value"}),
          ~s({"wall_time_seconds":0}),
          ~s({"max_model_turns":"2"})
        ] do
      error = assert_raise RuntimeError, fn -> read(value) end
      assert error.message =~ @variable
      refute error.message =~ "private-value"
      refute error.message =~ "private-field"
    end
  end

  test "test runtime ignores the operator shell setting" do
    assert read("private-value", :test) == %{}
  end

  defp read(value, env \\ :prod) do
    if is_nil(value), do: System.delete_env(@variable), else: System.put_env(@variable, value)
    Config.Reader.read!(@runtime_exs, env: env)[:fountain][:execution_limit_ceiling]
  end
end
