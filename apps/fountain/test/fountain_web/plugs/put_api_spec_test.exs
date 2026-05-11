defmodule FountainWeb.Plugs.PutApiSpecTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.Plugs.PutApiSpec

  describe "init/1" do
    test "returns a map with the given module and cache? flag" do
      opts = PutApiSpec.init(module: FountainWeb.ApiSpec)
      assert opts.module == FountainWeb.ApiSpec
      assert is_boolean(opts.cache?)
    end

    test "raises when :module option is missing" do
      assert_raise RuntimeError, ~r/:module/, fn ->
        PutApiSpec.init([])
      end
    end
  end

  describe "call/2 — cache?: true (production path)" do
    test "delegates to OpenApiSpex.Plug.PutApiSpec and does not halt the conn", %{conn: conn} do
      opts = %{module: FountainWeb.ApiSpec, cache?: true}
      result = PutApiSpec.call(conn, opts)
      refute result.halted
    end
  end

  describe "call/2 — cache?: false (dev/no-cache path)" do
    test "erases the cache and then delegates, conn is not halted", %{conn: conn} do
      # Call with cache?: false to exercise the erase+delegate branch.
      # OpenApiSpex.Plug.Cache.adapter().erase/1 is idempotent so this is safe
      # to run against a real (possibly empty) cache entry.
      opts = %{module: FountainWeb.ApiSpec, cache?: false}
      result = PutApiSpec.call(conn, opts)
      refute result.halted
    end
  end
end
