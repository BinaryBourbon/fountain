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

  # #571: the whole /api/auth/* surface was absent from the spec, because
  # Paths.from_router/1 only emits a path when the route's controller exports
  # open_api_operation/1 — and a controller that never `use`s ControllerSpecs
  # is skipped in silence. Nothing failed; the endpoints simply were not there.
  # This walks the router instead of the spec, so the next controller added
  # without an operation decl fails here rather than going missing quietly.
  describe "every /api/ route is in the spec (issue #571)" do
    # Each exception is a route under /api/ that is deliberately not part of
    # the documented JSON surface. Adding to this list is a decision, which is
    # the point of making it explicit.
    @exceptions [
      # The spec machinery itself — plugs, not controllers.
      {"/api/openapi.json", :get},
      {"/api/docs", :get},
      # Authenticated by Stripe-Signature, not a bearer token. Its caller is
      # Stripe, which does not read our spec.
      {"/api/stripe/webhook", :post},
      # A browser-session route that happens to live under /api/ — CSRF-
      # protected, session-authenticated, and driven by the theme toggle.
      {"/api/settings/theme", :patch}
    ]

    setup do
      spec = ApiSpec.spec()

      documented =
        for {path, item} <- spec.paths,
            {verb, %OpenApiSpex.Operation{}} <- Map.from_struct(item),
            into: MapSet.new(),
            do: {path, verb}

      %{documented: documented}
    end

    test "no /api/ route is undocumented", %{documented: documented} do
      undocumented =
        FountainWeb.Router.__routes__()
        |> Enum.filter(&String.starts_with?(&1.path, "/api/"))
        |> Enum.map(&{open_api_path(&1.path), &1.verb})
        |> Enum.reject(&(&1 in @exceptions or MapSet.member?(documented, &1)))
        |> Enum.uniq()

      assert undocumented == [],
             "these /api/ routes have no OpenAPI operation: #{inspect(undocumented)}. " <>
               "Add an `operation/2` decl to the controller, or add the route to " <>
               "@exceptions in this test with a reason."
    end

    test "every exception is still a live route" do
      live =
        FountainWeb.Router.__routes__()
        |> Enum.map(&{open_api_path(&1.path), &1.verb})
        |> MapSet.new()

      stale = Enum.reject(@exceptions, &MapSet.member?(live, &1))

      assert stale == [],
             "these @exceptions no longer match any route: #{inspect(stale)}"
    end

    test "the auth surface specifically is present", %{documented: documented} do
      for route <- [
            {"/api/auth/token", :post},
            {"/api/auth/me", :get},
            {"/api/auth/api-keys", :get},
            {"/api/auth/api-keys", :post},
            {"/api/auth/api-keys/{id}", :delete},
            {"/api/auth/register", :post},
            {"/api/auth/resend-verification", :post},
            {"/api/auth/verify", :post},
            {"/api/auth/forgot", :post},
            {"/api/auth/reset", :post},
            {"/api/auth/password", :post},
            {"/api/auth/email", :post},
            {"/api/auth/email/confirm", :post}
          ] do
        assert MapSet.member?(documented, route), "#{inspect(route)} is missing from the spec"
      end
    end

    # The spec carries a global bearer requirement. An endpoint you call
    # *before* you have a token must override it with `security: []`, or a
    # generated client refuses to call it without a credential it cannot have.
    test "public auth endpoints do not require a bearer token" do
      spec = ApiSpec.spec()

      for path <- [
            "/api/auth/token",
            "/api/auth/register",
            "/api/auth/resend-verification",
            "/api/auth/verify",
            "/api/auth/forgot",
            "/api/auth/reset",
            "/api/auth/email/confirm"
          ] do
        assert spec.paths[path].post.security == [],
               "#{path} must declare `security: []` — it is reachable without a key"
      end
    end

    # The mirror of the above: an authenticated endpoint that accidentally
    # declared `security: []` would document itself as public.
    test "authenticated auth endpoints inherit the bearer requirement" do
      spec = ApiSpec.spec()

      assert spec.paths["/api/auth/me"].get.security == nil
      assert spec.paths["/api/auth/api-keys"].post.security == nil
      assert spec.paths["/api/auth/password"].post.security == nil
    end
  end

  defp open_api_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> segment -> "{#{segment}}"
      segment -> segment
    end)
  end
end
