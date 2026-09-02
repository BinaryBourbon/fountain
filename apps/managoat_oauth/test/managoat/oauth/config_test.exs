defmodule Managoat.OAuth.ConfigTest do
  use ExUnit.Case, async: true

  alias Managoat.OAuth.Config

  test "an instance with no config raises naming the key, on the first call" do
    assert_raise ArgumentError,
                 ~r/config :managoat_oauth, Managoat.OAuth.UnconfiguredInstance, repo: MyApp.Repo/,
                 fn -> Managoat.OAuth.UnconfiguredInstance.clients() end
  end

  test "a configured instance loads repo, host, normalised clients and prefix" do
    assert %Config{
             repo: Managoat.OAuth.TestRepo,
             host: Managoat.OAuth.Host.Recording,
             prefix: nil,
             clients: [%{id: "test-app"}, %{id: "json-app"}]
           } = Managoat.OAuth.TestInstance.__managoat_oauth__()

    assert %Config{prefix: "managoat_oauth_scratch"} =
             Managoat.OAuth.PrefixedInstance.__managoat_oauth__()
  end

  test "repo_opts/1 is the prefix when there is one" do
    assert Config.repo_opts(%Config{}) == []
    assert Config.repo_opts(%Config{prefix: "s"}) == [prefix: "s"]
  end

  test "load!/3 refuses a nil host and a non-keyword config" do
    assert_raise ArgumentError, ~r/no host for Managoat.OAuth.TestInstance/, fn ->
      Config.load!(:managoat_oauth, Managoat.OAuth.TestInstance, nil)
    end

    Application.put_env(:managoat_oauth, __MODULE__.Odd, %{repo: :a_map_not_a_keyword})

    try do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Config.load!(:managoat_oauth, __MODULE__.Odd, Managoat.OAuth.Host.Recording)
      end
    after
      Application.delete_env(:managoat_oauth, __MODULE__.Odd)
    end
  end

  test "use without an otp_app or a host is a compile-time error" do
    assert_raise ArgumentError, ~r/otp_app: :my_app/, fn ->
      Code.compile_string("""
      defmodule Managoat.OAuth.ConfigTest.NoApp do
        use Managoat.OAuth, host: Managoat.OAuth.Host.Recording
      end
      """)
    end

    assert_raise ArgumentError, ~r/host: Module/, fn ->
      Code.compile_string("""
      defmodule Managoat.OAuth.ConfigTest.NoHost do
        use Managoat.OAuth, otp_app: :managoat_oauth
      end
      """)
    end
  end
end
