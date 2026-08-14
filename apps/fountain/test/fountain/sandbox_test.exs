defmodule Fountain.SandboxTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Sandbox
  alias Fountain.Sandbox.Command
  alias Fountain.Sandbox.Handle

  @name "fountain-abc12345-deadbeef"

  describe "provider resolution" do
    test "the known vocabulary is closed and sprites is the default" do
      assert Sandbox.known_providers() == ~w(sprites e2b daytona)
      assert Sandbox.default_provider() == :sprites
      assert Sandbox.adapter_for(:sprites) == Fountain.Sandbox.Sprites
    end

    test "an unconfigured provider raises with the configured set named" do
      assert_raise ArgumentError, ~r/unknown sandbox provider :daytona/, fn ->
        Sandbox.adapter_for(:daytona)
      end
    end

    test "supports? consults the adapter's capability set" do
      assert Sandbox.supports?(:sprites, :network_policy)
      assert Sandbox.supports?(:sprites, :suspend)
      refute Sandbox.supports?(:sprites, :checkpoint)

      handle = %Handle{provider: :sprites, name: @name}
      assert Sandbox.supports?(handle, :attach)
    end
  end

  describe "dispatch" do
    test "creation-side operations dispatch on the provider atom" do
      expect(Fountain.Sandbox.Sprites, :create, fn @name, [] ->
        {:ok, %Handle{provider: :sprites, name: @name}}
      end)

      assert {:ok, %Handle{name: @name}} = Sandbox.create(:sprites, @name)
    end

    test "handle-taking operations dispatch on the handle's provider tag" do
      handle = %Handle{provider: :sprites, name: @name}

      expect(Fountain.Sandbox.Sprites, :get, fn ^handle ->
        {:ok, %{status: :running, raw: %{}}}
      end)

      assert {:ok, %{status: :running}} = Sandbox.get(handle)
    end

    test "command-taking operations dispatch on the command's provider tag" do
      command = %Command{provider: :sprites, ref: make_ref()}

      expect(Fountain.Sandbox.Sprites, :write_stdin, fn ^command, "data" -> :ok end)
      assert :ok = Sandbox.write_stdin(command, "data")
    end

    test "build_handle is pure and provider-tagged" do
      assert %Handle{provider: :sprites, name: @name, private: nil} =
               Sandbox.build_handle(:sprites, @name)
    end
  end
end
