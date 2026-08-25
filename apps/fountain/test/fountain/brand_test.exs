defmodule Fountain.BrandTest do
  use ExUnit.Case, async: false

  alias Fountain.Brand

  setup do
    previous = Application.get_env(:fountain, :product_name)
    previous_assets = Application.get_env(:fountain, :brand_assets_url)

    on_exit(fn ->
      restore(:product_name, previous)
      restore(:brand_assets_url, previous_assets)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  test "unset or blank falls back to the engine, which is never hosted" do
    Application.delete_env(:fountain, :product_name)
    assert Brand.name() == "Fountain"
    refute Brand.hosted?()

    Application.put_env(:fountain, :product_name, "   ")
    assert Brand.name() == "Fountain"
    refute Brand.hosted?()
  end

  test "a brand is trimmed, used, and marks the deployment hosted" do
    Application.put_env(:fountain, :product_name, " Managoat ")
    assert Brand.name() == "Managoat"
    assert Brand.engine() == "Fountain"
    assert Brand.hosted?()
  end

  test "without a bundle the assets are the built-in files, on the same origin" do
    Application.delete_env(:fountain, :brand_assets_url)
    assert Brand.assets_url() == nil
    assert Brand.assets_origin() == nil
    assert Brand.asset("favicon.ico") == "/favicon.ico"
    assert Brand.asset("app-icon.png") == "/images/app-icon.png"
    assert Brand.asset("og-card.png") == "/images/og-card.png"

    Application.put_env(:fountain, :brand_assets_url, "  ")
    assert Brand.assets_url() == nil
    assert Brand.asset("app-icon.png") == "/images/app-icon.png"
  end

  test "a bundle URL is trimmed, its trailing slash dropped, and every asset resolved under it" do
    Application.put_env(:fountain, :brand_assets_url, " https://cdn.example.com:8443/brand/ ")
    assert Brand.assets_url() == "https://cdn.example.com:8443/brand"
    assert Brand.assets_origin() == "https://cdn.example.com:8443"
    assert Brand.asset("favicon.ico") == "https://cdn.example.com:8443/brand/favicon.ico"
    assert Brand.asset("og-card.png") == "https://cdn.example.com:8443/brand/og-card.png"

    for name <- Brand.assets() do
      assert Brand.asset(name) == "https://cdn.example.com:8443/brand/" <> name
    end
  end

  test "the origin omits a default port" do
    Application.put_env(:fountain, :brand_assets_url, "https://cdn.example.com:443/brand")
    assert Brand.assets_origin() == "https://cdn.example.com"
  end

  test "only the six bundle files resolve" do
    assert_raise FunctionClauseError, fn -> Brand.asset("logo.svg") end
  end
end
