defmodule FountainWeb.Plugs.WebAnalyticsTest do
  @moduledoc """
  Which pages load posthog-js, and which deliberately do not.

  The split is the whole design: the public surface needs a browser to say
  anything about visitors (sessions, referrers, devices — and anyone who is
  not signed in at all), while the console is captured server-side and would
  double-count if it ran both.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = %{
      key: Application.get_env(:fountain, :posthog_project_api_key),
      host: Application.get_env(:fountain, :posthog_host),
      browser: Application.get_env(:fountain, :analytics_browser_capture)
    }

    Application.put_env(:fountain, :posthog_project_api_key, "phc_test")
    Application.put_env(:fountain, :posthog_host, "https://us.i.posthog.com")
    Fountain.FeatureFlags.reset()

    on_exit(fn ->
      restore(:posthog_project_api_key, previous.key)
      restore(:posthog_host, previous.host)
      restore(:analytics_browser_capture, previous.browser)
      Fountain.FeatureFlags.reset()
    end)

    Req.Test.stub(Fountain.Analytics, fn conn -> Req.Test.json(conn, %{"status" => 1}) end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp snippet?(html), do: html =~ "posthog.init("

  describe "the public surface" do
    test "the landing page loads the snippet", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert snippet?(html)
      assert html =~ "https://us-assets.i.posthog.com/static/array.js"

      # Config arrives as attributes, which HEEx escapes, rather than as
      # values concatenated into the JS.
      assert html =~ ~s(data-api-key="phc_test")
      assert html =~ ~s(data-api-host="https://us.i.posthog.com")
    end

    test "the login page loads it — the last page before an account exists", %{conn: conn} do
      assert conn |> get(~p"/auth/login") |> html_response(200) |> snippet?()
    end

    test "the register page loads it", %{conn: conn} do
      assert conn |> get(~p"/auth/register") |> html_response(200) |> snippet?()
    end

    test "the manual loads it", %{conn: conn} do
      assert conn |> get(~p"/docs") |> html_response(200) |> snippet?()
    end

    test "the legal pages load it", %{conn: conn} do
      assert conn |> get(~p"/privacy") |> html_response(200) |> snippet?()
      assert conn |> get(~p"/terms") |> html_response(200) |> snippet?()
    end

    test "a signed-in visitor reading the marketing page is still counted", %{conn: conn} do
      # Being logged in does not make someone stop being a visitor to these
      # pages, and gating on the session would put a hole in the funnel
      # exactly where returning users are.
      user = insert_verified_user()

      assert conn |> login_user(user) |> get(~p"/") |> html_response(200) |> snippet?()
    end

    test "the snippet keeps anonymous readers from minting person profiles", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(person_profiles: "identified_only")
    end

    test "every public event is tagged, so the two surfaces stay separable", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|register({ surface: "public" })|
    end

    test "recording masks what people type, and says so rather than inheriting it", %{conn: conn} do
      # Replay is on in the PostHog *project*, so posthog-js records these
      # pages whether or not this file mentions it. Stating the masking is what
      # keeps it from changing when a dependency's default does — and the
      # public surface includes the two pages with a form worth typing into.
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s|session_recording: { maskAllInputs: true }|
    end

    test "the auth pages, where people type, carry the same masking", %{conn: conn} do
      for path <- [~p"/auth/login", ~p"/auth/register"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s|session_recording: { maskAllInputs: true }|,
               "#{path} is recorded without stating that inputs are masked"
      end
    end
  end

  describe "the console" do
    setup %{conn: conn} do
      {:ok, conn: login_user(conn, insert_verified_user())}
    end

    test "a LiveView page loads no snippet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute snippet?(html)
    end

    test "the admin pages load no library, so nothing there is ever recorded", %{conn: conn} do
      # The public pages are session recorded (ADR 0028). The console is not,
      # because it loads no library — and that is the whole of the protection,
      # so it is worth pinning where it matters most rather than trusting that
      # nobody adds :public_analytics to a wider scope later. /admin/finance is
      # a revenue page; /admin lists accounts.
      {:ok, admin} = Fountain.Accounts.update_user_role(insert_verified_user(), "admin")
      conn = login_user(conn, admin)

      for path <- [~p"/admin", ~p"/admin/finance"] do
        html = conn |> get(path) |> html_response(200)

        refute snippet?(html), "#{path} rendered the analytics snippet"
        refute html =~ "array.js", "#{path} loaded posthog-js"
      end
    end

    test "the console's dead render loads neither the snippet nor the library", %{conn: conn} do
      # The dead render goes through the same root layout as the public pages,
      # so it is the place a mis-scoped assign would show up first. If array.js
      # loaded here, posthog-js would autocapture a pageview on top of the one
      # `FountainWeb.Live.Hooks` already sends, doubling every console number.
      html = conn |> get(~p"/dashboard") |> html_response(200)

      refute snippet?(html)
      refute html =~ "array.js"
    end
  end

  describe "when the operator has turned it off" do
    test "no project key means no snippet", %{conn: conn} do
      Application.delete_env(:fountain, :posthog_project_api_key)

      refute conn |> get(~p"/") |> html_response(200) |> snippet?()
    end

    test "POSTHOG_BROWSER_CAPTURE=false means no snippet", %{conn: conn} do
      Application.put_env(:fountain, :analytics_browser_capture, false)

      refute conn |> get(~p"/") |> html_response(200) |> snippet?()
    end
  end

  describe "the content security policy" do
    defp csp(conn), do: conn |> Plug.Conn.get_resp_header("content-security-policy") |> hd()

    defp directive(csp, name) do
      csp |> String.split("; ") |> Enum.find(&String.starts_with?(&1, name <> " "))
    end

    test "a public page admits both PostHog origins, or the browser blocks the snippet", %{
      conn: conn
    } do
      csp = conn |> get(~p"/") |> csp()

      # Both directives, for two different requests: one to fetch array.js,
      # one to POST to /batch/. Missing either silently breaks capture in the
      # browser while everything still looks right on the server.
      assert directive(csp, "script-src") =~ "https://us-assets.i.posthog.com"
      assert directive(csp, "connect-src") =~ "https://us.i.posthog.com"
    end

    test "a console page names no PostHog origin at all", %{conn: conn} do
      # The console loads no analytics script, so its policy stays exactly as
      # tight as it was. Widening only where the script actually runs is the
      # reason this lives in the plug rather than in the router's @csp.
      csp = conn |> login_user(insert_verified_user()) |> get(~p"/dashboard") |> csp()

      refute csp =~ "posthog"
    end

    test "widening does not disturb the directives it does not touch", %{conn: conn} do
      csp = conn |> get(~p"/") |> csp()

      assert directive(csp, "img-src") == "img-src 'self' data:"
      assert directive(csp, "style-src") == "style-src 'self' 'unsafe-inline'"
      assert directive(csp, "script-src") =~ "'unsafe-inline'"
      assert directive(csp, "script-src") =~ "https://cdn.tailwindcss.com"
      assert directive(csp, "connect-src") =~ "ws: wss:"
    end

    test "with capture off the policy is the console's", %{conn: conn} do
      Application.delete_env(:fountain, :posthog_project_api_key)

      refute conn |> get(~p"/") |> csp() =~ "posthog"
    end

    test "follows POSTHOG_HOST, so a self-hosted PostHog is not blocked by a stale header", %{
      conn: conn
    } do
      # The reason this is built per request: POSTHOG_HOST is read in
      # runtime.exs, so a compile-time policy would carry whatever the build
      # saw — for a release, nothing.
      Application.put_env(:fountain, :posthog_host, "https://posthog.internal.example")

      csp = conn |> get(~p"/") |> csp()

      assert csp =~ "https://posthog.internal.example"
      refute csp =~ "posthog.com"
    end

    test "keeps the directives it already had", %{conn: conn} do
      csp = conn |> get(~p"/") |> csp()

      assert csp =~ "default-src 'self'"
      assert csp =~ "frame-ancestors 'self'"
      assert csp =~ "form-action 'self'"
      assert csp =~ "object-src 'none'"
      assert csp =~ "https://cdn.tailwindcss.com"
      assert csp =~ "https://cdn.jsdelivr.net"
    end
  end
end
