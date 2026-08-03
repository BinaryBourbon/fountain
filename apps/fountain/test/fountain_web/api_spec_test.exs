defmodule FountainWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  alias FountainWeb.ApiSpec

  # #403: the published spec described the pre-rename identity ("Agent on
  # Demand", the `aod` CLI) and an auth mechanism that no longer exists
  # (ADMIN_TOKEN). Pin the real identity and auth scheme.
  describe "spec/0 identity and auth (issue #403)" do
    setup do
      spec = ApiSpec.spec()
      %{info: spec.info, bearer: spec.components.securitySchemes["bearer"]}
    end

    test "info names the current product and CLI", %{info: info} do
      assert info.title == "Fountain"
      refute info.description =~ "Agent on Demand"
      refute info.description =~ "`aod`"
      assert info.description =~ "`fountain` CLI"
    end

    test "info describes API-key auth, not ADMIN_TOKEN", %{info: info} do
      refute info.description =~ "ADMIN_TOKEN"
      assert info.description =~ "API key"
      assert info.description =~ "POST /api/auth/api-keys"
      assert info.description =~ "POST /api/auth/token"
    end

    test "bearer security scheme describes API keys, not ADMIN_TOKEN", %{bearer: bearer} do
      assert bearer.type == "http"
      assert bearer.scheme == "bearer"
      refute bearer.description =~ "ADMIN_TOKEN"
      assert bearer.description =~ "API key"
      assert bearer.description =~ "POST /api/auth/api-keys"
    end
  end
end
