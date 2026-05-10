defmodule FountainWeb.Router do
  use FountainWeb, :router

  ## ─── Pipelines ─────────────────────────────────────────────────────────────────

  # Public JSON — spec rendering, health, public auth endpoints
  pipeline :api_public do
    plug :accepts, ["json"]
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
  end

  # Authenticated JSON — TenantAPIAuth gate for all resource endpoints
  pipeline :api do
    plug :accepts, ["json"]
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
    plug FountainWeb.Plugs.TenantAPIAuth
    plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 600
    plug FountainWeb.Plugs.Audit
  end

  # Base browser pipeline — session, flash, CSRF, secure headers
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FountainWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Public browser routes (login, register, verify) — no auth check
  pipeline :browser_public do
    # intentionally empty; inherits :browser
  end

  # Authenticated browser routes — loads current_user from session
  pipeline :browser_authenticated do
    plug FountainWeb.Plugs.TenantSessionAuth
  end

  # Legacy single-tenant admin pipeline (kept for ops/upgrade endpoints)
  pipeline :authed_admin do
    plug FountainWeb.Plugs.SessionAuth
  end

  ## ─── Public routes ───────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through :api_public
    get "/health", HealthController, :show
  end

  scope "/api" do
    pipe_through :api_public
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  ## ─── Public browser routes ──────────────────────────────────────────────────

  # Legacy single-tenant admin login (kept for ops runbook compat)
  scope "/", FountainWeb do
    pipe_through :browser

    get "/login", SessionController, :legacy_new
    post "/login", SessionController, :legacy_create
    post "/logout", SessionController, :legacy_delete
    get "/logout", SessionController, :legacy_delete
  end

  # Multi-tenant auth routes (no session auth required)
  scope "/auth", FountainWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", SessionController, :delete

    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
    get "/check-email", RegistrationController, :check_email

    get "/forgot-password", PasswordResetController, :forgot_form
    get "/reset/:token", PasswordResetController, :reset_form
    post "/reset", PasswordResetController, :reset

    # Ueberauth OAuth routes
    get "/oauth/:provider", UeberauthController, :request
    get "/oauth/:provider/callback", UeberauthController, :callback
  end

  # Email verification (token in path)
  scope "/users", FountainWeb do
    pipe_through :browser
    get "/confirm/:token", EmailVerificationController, :confirm
  end

  ## ─── Public JSON auth endpoints ──────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through :api_public

    post "/token", AuthTokenController, :create
    post "/register", RegistrationController, :api_create
    post "/forgot", PasswordResetController, :api_forgot
  end

  ## ─── Stripe webhook (phase-3-billing) ─────────────────────────────────────────────
  # No TenantAPIAuth: authenticated via Stripe-Signature header verification.
  # Must be reachable by Stripe's servers without a bearer token.

  scope "/api/stripe", FountainWeb do
    pipe_through :api_public
    post "/webhook", StripeWebhookController, :create
  end

  ## ─── Authenticated JSON resource endpoints ──────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through :api

    get "/me", AuthMeController, :show
    post "/api-keys", ApiKeyController, :create
    delete "/api-keys/:id", ApiKeyController, :delete
  end

  scope "/api", FountainWeb do
    pipe_through :api

    resources "/environments", EnvironmentController, except: [:new, :edit] do
      resources "/secrets", SecretController, only: [:index, :create, :delete]
    end

    resources "/vaults", VaultController, except: [:new, :edit] do
      resources "/secrets", VaultSecretController, only: [:index, :create, :delete]
    end

    resources "/agents", AgentController, except: [:new, :edit]

    resources "/conversations", ConversationController,
      only: [:index, :show, :create, :delete] do
      post "/prompts", ConversationController, :prompt, as: :prompt
      post "/interrupt", ConversationController, :interrupt, as: :interrupt
      post "/terminate", ConversationController, :terminate, as: :terminate
      get "/stream", ConversationController, :stream, as: :stream
      get "/turns", ConversationController, :turns, as: :turns
      get "/turns/:turn_id/images/:position", TurnImageController, :show, as: :turn_image
    end
  end

  ## ─── Authenticated browser / LiveView routes ───────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through [:browser, :browser_authenticated]

    # ── Theme preference — CSRF-protected, session-authenticated ────────────────
    patch "/api/settings/theme", SettingsController, :update_theme

    # ── Phase-3-billing: conversation routes require an active subscription ─────────
    # :require_active_subscription runs after :require_authenticated_user and
    # redirects to /account/billing on SubscriptionRequiredError.
    live_session :active_subscription,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Live.Hooks, :require_active_subscription},
        {FountainWeb.Hooks.UpdateCheckerHook, :default}
      ] do
      live "/", ConversationsLive.Index, :index
      live "/conversations/new", ConversationsLive.New, :new
      live "/conversations/:id", ConversationsLive.Show, :show
    end

    # ── Read-only and settings routes — no subscription gate ────────────────
    # Users can reach these routes even when past_due / canceled so they can
    # view past logs, manage resources, complete onboarding, and update payment
    # details. See decisions/0006-hard-stripe-billing-gate-at-launch.md.
    live_session :authenticated,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Hooks.UpdateCheckerHook, :default}
      ] do
      live "/dashboard", DashboardLive.Index, :index
      live "/onboarding", OnboardingLive.Wizard, :index
      live "/onboarding/:step", OnboardingLive.Wizard, :show
      live "/conversations/:id/logs", LogViewerLive.Show, :show
      live "/agents", AgentsLive.Index, :index
      live "/agents/new", AgentsLive.Form, :new
      live "/agents/:id/edit", AgentsLive.Form, :edit
      live "/environments", EnvironmentsLive.Index, :index
      live "/environments/new", EnvironmentsLive.Form, :new
      live "/environments/:id/edit", EnvironmentsLive.Form, :edit
      live "/vaults", VaultsLive.Index, :index
      live "/vaults/new", VaultsLive.Form, :new
      live "/vaults/:id/edit", VaultsLive.Form, :edit
      live "/audit", AuditLive.Index, :index
      live "/api-keys", ApiKeysLive.Index, :index
      live "/help", HelpLive.Show, :index
      live "/help/:topic", HelpLive.Show, :show
      # ── Phase-3-billing: account/billing ───────────────────────────────────
      live "/account/billing", Live.BillingLive, :index
      # ── BYO inference credentials (ADR 0008) ───────────────────────────────
      live "/account/inference-credentials", InferenceCredentialsLive.Index, :index
    end

    live_session :admin,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Live.Hooks, :require_admin},
        {FountainWeb.Hooks.UpdateCheckerHook, :default}
      ] do
      live "/admin", AdminLive.Index, :index
    end
  end

  ## ─── Legacy admin-only routes ──────────────────────────────────────────────────

  scope "/admin", FountainWeb do
    pipe_through [:browser, :authed_admin]
    post "/upgrade", AdminController, :upgrade
  end

  ## ─── Dev dashboard ─────────────────────────────────────────────────────────────

  if Application.compile_env(:fountain, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser]
      live_dashboard "/dashboard", metrics: FountainWeb.Telemetry
    end
  end
end
