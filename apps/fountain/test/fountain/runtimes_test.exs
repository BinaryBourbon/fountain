defmodule Fountain.RuntimesTest do
  use ExUnit.Case, async: true

  alias Fountain.Runtimes

  describe "for_runtime/1" do
    test "returns {:ok, module} for known runtimes" do
      for name <- ~w(claude codex gemini opencode) do
        assert {:ok, mod} = Runtimes.for_runtime(name)
        assert is_atom(mod)
      end
    end

    test "returns {:error, message} for an unknown runtime" do
      assert {:error, msg} = Runtimes.for_runtime("unknown_runtime")
      assert msg =~ "unsupported runtime"
    end
  end
end
