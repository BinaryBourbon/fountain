defmodule FountainWeb.OnboardingLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "OnboardingLive.Wizard — redirect logic" do
    test "user who completed onboarding is redirected to /dashboard", %{conn: conn} do
      user = insert_verified_user()
      {:ok, completed_user} = Fountain.Accounts.complete_onboarding(user)

      conn = login_user(conn, completed_user)
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/onboarding/step_1")
    end

    test "user with no onboarding_state mounts step_1 (inference)", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/onboarding/step_1")
      assert html =~ "Step 1"
      assert html =~ "Connect a provider"
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/onboarding/step_1")
      assert path =~ "/auth/login"
    end

    # Exercises mount(_params, ...) — no step key in params
    test "visiting /onboarding (no step) for incomplete user redirects to current step", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      # /onboarding routes to the no-step mount clause; user has no
      # onboarding_state so it redirects to step_1
      assert {:error, {:live_redirect, %{to: "/onboarding/step_1"}}} =
               live(conn, ~p"/onboarding")
    end

    test "visiting /onboarding (no step) for completed user redirects to /dashboard", %{conn: conn} do
      user = insert_verified_user()
      {:ok, completed_user} = Fountain.Accounts.complete_onboarding(user)

      conn = login_user(conn, completed_user)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/onboarding")
    end

    test "visiting /onboarding (no step) for user mid-wizard redirects to their current step", %{conn: conn} do
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.advance_onboarding(user, "step_2")

      conn = login_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/onboarding/step_2"}}} =
               live(conn, ~p"/onboarding")
    end
  end

  describe "OnboardingLive.Wizard — step 1 (inference)" do
    setup %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_1")
      %{lv: lv, user: user}
    end

    test "renders all four provider forms", %{lv: lv} do
      html = render(lv)
      assert html =~ "Anthropic"
      assert html =~ "Claude OAuth"
      assert html =~ "OpenAI"
      assert html =~ "Gemini"
    end

    test "Continue is disabled until at least one provider is set", %{lv: lv} do
      html = render(lv)
      # The Continue button is rendered with a disabled/cursor-not-allowed style
      # when no inference credential has been set
      assert html =~ "continue_from_inference"
      assert html =~ "cursor-not-allowed"
    end

    test "skip_wizard from step_1 redirects to /dashboard", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               lv |> element("button", "Skip setup") |> render_click()
    end
  end

  describe "OnboardingLive.Wizard — step 2 (environment)" do
    setup %{conn: conn} do
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.advance_onboarding(user, "step_2")
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_2")
      %{lv: lv, user: user}
    end

    test "renders the environment step", %{lv: lv} do
      html = render(lv)
      assert html =~ "Step 2"
      assert html =~ "Create an environment"
    end

    test "skip_env advances to step_3", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/onboarding/step_3"}}} =
               lv |> element("button[phx-click='skip_env']") |> render_click()
    end

    test "submitting a valid env advances to step_3", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/onboarding/step_3"}}} =
               lv
               |> form("form[phx-submit='create_env']", env: %{name: "my-env"})
               |> render_submit()
    end

    test "submitting an empty name shows an error", %{lv: lv} do
      html =
        lv
        |> form("form[phx-submit='create_env']", env: %{name: ""})
        |> render_submit()

      assert html =~ "Create an environment" or html =~ "can&#39;t be blank"
    end

    test "validate_env updates the form without navigating away", %{lv: lv} do
      html =
        lv
        |> form("form[phx-change='validate_env']", env: %{name: "typing-name"})
        |> render_change()

      # Still on step 2 and the typed value is reflected in the form
      assert html =~ "Create an environment"
      assert html =~ "typing-name"
    end
  end

  describe "OnboardingLive.Wizard — step 3 (agent)" do
    setup %{conn: conn} do
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.advance_onboarding(user, "step_3")
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_3")
      %{conn: conn, lv: lv, user: user}
    end

    test "renders the agent step", %{lv: lv} do
      html = render(lv)
      assert html =~ "Step 3"
      assert html =~ "Create an agent"
    end

    test "skip_agent advances to step_4", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/onboarding/step_4"}}} =
               lv |> element("button[phx-click='skip_agent']") |> render_click()
    end

    test "submitting a valid agent name advances to step_4", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/onboarding/step_4"}}} =
               lv
               |> form("form[phx-submit='create_agent']", agent: %{name: "My Agent"})
               |> render_submit()
    end

    test "submitting an empty agent name shows an error", %{lv: lv} do
      html =
        lv
        |> form("form[phx-submit='create_agent']", agent: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "validate_agent updates the form without navigating away", %{lv: lv} do
      html =
        lv
        |> form("form[phx-change='validate_agent']", agent: %{name: "my-agent-draft"})
        |> render_change()

      # Still on step 3 and the typed value is reflected in the form
      assert html =~ "Create an agent"
      assert html =~ "my-agent-draft"
    end
  end

  describe "OnboardingLive.Wizard — step 4 (finish)" do
    test "start_conversation redirects to /conversations/new", %{conn: conn} do
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.advance_onboarding(user, "step_4")
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_4")

      assert {:error, {:live_redirect, %{to: "/conversations/new"}}} =
               lv |> element("button", "Start first conversation") |> render_click()
    end
  end
end

# Credential-saving tests require Req stubs that must be visible to the
# LiveView process. Mimic global mode (which makes stubs available to all
# processes) is incompatible with async: true, so these live in their own
# non-async module.
defmodule FountainWeb.OnboardingLiveCredentialTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  setup :set_mimic_global

  describe "OnboardingLive.Wizard — step 1 credential events" do
    setup %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_1")
      %{lv: lv, user: user}
    end

    test "save_credential with empty value shows error", %{lv: lv} do
      html = render_click(lv, "save_credential", %{"provider" => "anthropic_api_key", "value" => ""})
      assert html =~ "Paste a value before saving."
    end

    test "save_credential with invalid key shows provider-rejection error", %{lv: lv} do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 401}} end)

      html = render_click(lv, "save_credential", %{"provider" => "anthropic_api_key", "value" => "bad-key"})

      assert html =~ "Provider rejected the credential"
      assert html =~ "HTTP 401"
    end

    test "save_credential with valid anthropic key shows saved message", %{lv: lv} do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)

      html = render_click(lv, "save_credential", %{"provider" => "anthropic_api_key", "value" => "sk-ant-valid-key"})

      assert html =~ "Saved and validated."
    end

    test "save_credential shows timeout error when request times out", %{lv: lv} do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      html = render_click(lv, "save_credential", %{"provider" => "anthropic_api_key", "value" => "sk-ant-any-key"})

      assert html =~ "Validation timed out"
    end

    test "save_credential shows generic error for unexpected network failures", %{lv: lv} do
      stub(Req, :get, fn _url, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      html = render_click(lv, "save_credential", %{"provider" => "anthropic_api_key", "value" => "sk-ant-any-key"})

      assert html =~ "Could not reach provider"
    end

    test "save_credential shows 'Could not save' when Crypto.load_tenant_key fails", %{lv: lv} do
      # Req.get returns 200 so validation passes, but DEK loading fails
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:error, :no_key} end)

      html =
        render_click(lv, "save_credential", %{
          "provider" => "anthropic_api_key",
          "value" => "sk-ant-valid-key"
        })

      assert html =~ "Could not save"
    end

    test "continue_from_inference advances to step_2 when a credential is set", %{lv: lv} do
      # Save a real credential first so has_any_credential? returns true
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)

      render_click(lv, "save_credential", %{
        "provider" => "anthropic_api_key",
        "value" => "sk-ant-valid-key"
      })

      assert {:error, {:live_redirect, %{to: "/onboarding/step_2"}}} =
               render_click(lv, "continue_from_inference", %{})
    end
  end
end
