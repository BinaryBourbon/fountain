# async: false — these mutate the global :marketing_site / :registration_enabled
# app env, which config/test.exs pins for the whole suite.
defmodule FountainWeb.MarketingInstanceTest do
  use FountainWeb.ConnCase, async: false

  setup do
    marketing = Application.get_env(:fountain, :marketing_site)
    registration = Application.get_env(:fountain, :registration_enabled)

    on_exit(fn ->
      Application.put_env(:fountain, :marketing_site, marketing)
      Application.put_env(:fountain, :registration_enabled, registration)
    end)

    :ok
  end

  describe "GET / where the deployment is not the marketing site" do
    setup do
      Application.put_env(:fountain, :marketing_site, false)
      :ok
    end

    test "serves a plain front door and none of the pitch", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "This instance runs agents on sandboxes"
      assert body =~ ~p"/auth/login"
      assert body =~ "/docs"

      refute body =~ "You did not set out to run a sandbox platform."
      refute body =~ "What you stop building."
      refute body =~ "14-day trial"
      refute body =~ "Managed agent infrastructure"

      # The Open Graph card follows the same rule: no pitch, only what it is.
      assert body =~
               ~s(<meta property="og:description" content="Fountain runs agents on sandboxes)

      assert body =~ ~s(<meta property="og:image:alt" content="Fountain")
    end

    # The footer groups its links now. A deployment that is not the marketing
    # site has nothing to put under Product, so the whole group goes rather
    # than leaving a heading over an empty column.
    test "keeps only the footer groups it can fill", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      refute body =~ ~s(data-role="footer-product")
      assert body =~ ~s(data-role="footer-learn")
      assert body =~ ~s(data-role="footer-account")

      refute body =~ ~p"/integrations"
      refute body =~ ~p"/built-with"
      refute body =~ ~p"/self-hosted"
      refute body =~ ~p"/case-studies/self-healing-infrastructure"
    end

    test "keeps the price off the page even with a price configured", %{conn: conn} do
      Application.put_env(:fountain, :stripe_price_monthly_cents, 2900)
      on_exit(fn -> Application.delete_env(:fountain, :stripe_price_monthly_cents) end)

      refute conn |> get(~p"/") |> html_response(200) =~ "/mo per user"
    end

    test "offers registration while registration is open", %{conn: conn} do
      Application.put_env(:fountain, :registration_enabled, true)

      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/auth/register"
      assert body =~ "Create an account"
    end

    test "drops every registration link once registration is closed", %{conn: conn} do
      Application.put_env(:fountain, :registration_enabled, false)

      # Not only the page's own CTA: the shared marketing layout's nav and
      # footer link it too, and a link to a door the context refuses is worse
      # than no link.
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/auth/register"
    end

    test "points a signed-in visitor at the console", %{conn: conn} do
      user = insert_verified_user()

      body = conn |> login_user(user) |> get(~p"/") |> html_response(200)
      assert body =~ "Open the console"
      assert body =~ ~p"/dashboard"
      refute body =~ ~p"/auth/register"
    end
  end

  describe "GET /integrations where the deployment is not the marketing site" do
    test "sends the visitor to the manual's own list rather than the pitch", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, false)

      conn = get(conn, ~p"/integrations")
      assert redirected_to(conn) == ~p"/docs/integrations/clients"

      # The layout drops the link too: a nav entry to a redirect is a dead end.
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/integrations"
    end
  end

  describe "GET /built-with where the deployment is not the marketing site" do
    test "sends the visitor to the build guide rather than somebody else's apps", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, false)

      conn = get(conn, ~p"/built-with")
      assert redirected_to(conn) == ~p"/docs/build"

      # The layout drops the link too: a nav entry to a redirect is a dead end.
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/built-with"
    end
  end

  describe "GET /self-hosted where the deployment is not the marketing site" do
    test "sends the visitor to the operator's manual rather than the pitch", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, false)

      conn = get(conn, ~p"/self-hosted")
      assert redirected_to(conn) == ~p"/docs/self-hosting"

      # The layout drops the link too: a nav entry to a redirect is a dead end.
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/self-hosted"
    end
  end

  describe "GET /code-review-bot where the deployment is not the marketing site" do
    test "sends the visitor to the manual's own walkthrough of the job", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, false)

      conn = get(conn, ~p"/code-review-bot")
      assert redirected_to(conn) == ~p"/docs/tour"

      # No "the layout drops the link" assertion here, unlike its neighbours:
      # the page is unlisted on the marketing site too, so there is no link for
      # a non-marketing deployment to drop. The marketing-site test owns that.
    end
  end

  describe "GET /case-studies where the deployment is not the marketing site" do
    test "sends the visitor to the manual rather than somebody else's sales copy", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, false)

      assert redirected_to(get(conn, ~p"/case-studies/self-healing-infrastructure")) ==
               ~p"/docs/tour"

      assert redirected_to(get(conn, ~p"/case-studies")) == "/docs"

      # The layout drops the footer link too, for the same reason as
      # /integrations above.
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/case-studies"
    end
  end

  describe "GET / on the marketing site" do
    test "still serves the pitch", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, true)

      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "You did not set out to run a sandbox platform."
      assert body =~ "Managed agent infrastructure"
      refute body =~ "This instance runs agents on sandboxes"
    end
  end
end
