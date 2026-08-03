defmodule FountainWeb.Router do
  @moduledoc false
  use FountainWeb, :router

  ## ─── Pipelines ──────────────────────────────────────────────────────────────────────────────────

  # Public JSON — spec rendering, health, public auth endpoints
  pipeline :api_public do
    plug :accepts, ["json"]
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
  end

  # Authenticated API — TenantAPIAuth gate for all resource endpoints.
  #
  # Content negotiation is deliberately NOT part of this pipeline. Every
  # authenticated route pipes through `:accepts_json` as well, except the SSE
  # stream, which cannot: a real EventSource client sends
  # `Accept: text/event-stream`, and `plug :accepts, ["json"]` refuses that with
  # 406 before the action ever runs. Keeping the auth chain in one pipeline
  # means the stream route cannot drift out of it — a second copy of these
  # plugs would be one forgotten line away from an unauthenticated endpoint.
  pipeline :api do
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
    # RateLimit BEFORE TenantAPIAuth (#316): auth halts on failure, so with
    # the old order the limiter only ever saw authenticated requests —
    # unauthenticated callers got unlimited attempts, each costing a SHA-256
    # plus an indexed api_keys lookup. This was the one auth surface without
    # a pre-auth limit; session login, registration, password reset and
    # POST /api/auth/token all have one.
    plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 600
    plug FountainWeb.Plugs.TenantAPIAuth
    plug FountainWeb.Plugs.Audit
  end

  pipeline :accepts_json do
    plug :accepts, ["json"]
  end

  # As tight as the current asset setup allows: the root layout runs Tailwind
  # and Phoenix/LiveView/d3 off CDNs and carries large inline scripts and
  # onclick handlers, so script-src needs 'unsafe-inline' plus the two CDN
  # hosts (a nonce scheme can't cover inline event handlers). That means this
  # CSP does NOT block javascript: URLs — FountainWeb.Markdown filters those
  # at render time (#323). What it does pin down: no framing, no <object>,
  # no off-origin form posts, fetch/websocket restricted to self + the LV
  # socket, images to self + the data: URLs the image picker and avatars use.
  @csp [
         "default-src 'self'",
         "base-uri 'self'",
         "frame-ancestors 'self'",
         "form-action 'self'",
         "object-src 'none'",
         "img-src 'self' data:",
         "style-src 'self' 'unsafe-inline'",
         "script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net",
         "connect-src 'self' ws: wss:"
       ]
       |> Enum.join("; ")

  # Base browser pipeline — session, flash, CSRF, secure headers
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FountainWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  # Public browser routes (login, register, verify) — no auth check
  pipeline :browser_public do
    # intentionally empty; inherits :browser
  end

  # Authenticated browser routes — loads current_user from session
  pipeline :browser_authenticated do
    plug FountainWeb.Plugs.TenantSessionAuth
  end

  # Optional browser auth — loads current_user if session exists, no redirect if absent
  pipeline :browser_optional_auth do
    plug FountainWeb.Plugs.OptionalSessionAuth
  end

  # Layered on top of :api for routes that manage API keys themselves.
  pipeline :require_key_management do
    plug FountainWeb.Plugs.RequireKeyManagement
  end

  ## ─── Public routes ────────────────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through :api_public
    # Liveness: static. Readiness: checks the dependencies this instance cannot
    # serve without. See FountainWeb.HealthController for why they are separate.
    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  # llms.txt convention (https://llmstxt.org/) + external SKILL.md for agentic IDEs.
  # No pipeline: plain-text GETs with no auth, no CSRF, no session. The
  # controller sets `text/plain; charset=utf-8` explicitly.
  scope "/", FountainWeb do
    get "/llms.txt", LlmsController, :index
    get "/llms-full.txt", LlmsController, :full
    get "/skill", LlmsController, :skill
    get "/skills/fountain/SKILL.md", LlmsController, :skill
  end

  scope "/api" do
    pipe_through :api_public
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  ## ─── Public browser routes ────────────────────────────────────────────────────────────────────────

  # Marketing landing page — public, shows auth-aware nav for logged-in users
  scope "/", FountainWeb do
    pipe_through [:browser, :browser_optional_auth]
    get "/", MarketingController, :home
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

  ## ─── Public JSON auth endpoints ───────────────────────────────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through :api_public

    post "/token", AuthTokenController, :create
    post "/register", RegistrationController, :api_create
    post "/forgot", PasswordResetController, :api_forgot
  end

  ## ─── Stripe webhook (phase-3-billing) ───────────────────────────────────────────────────────────────────
  # No TenantAPIAuth: authenticated via Stripe-Signature header verification.
  # Must be reachable by Stripe's servers without a bearer token.

  scope "/api/stripe", FountainWeb do
    pipe_through :api_public
    post "/webhook", StripeWebhookController, :create
  end

  ## ─── Authenticated JSON resource endpoints ──────────────────────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api]

    get "/me", AuthMeController, :show
  end

  # Key management is scope-gated: the per-conversation token a sprite holds
  # must not be able to mint a second key that survives conversation teardown.
  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_key_management]

    get "/api-keys", ApiKeyController, :index
    post "/api-keys", ApiKeyController, :create
    delete "/api-keys/:id", ApiKeyController, :delete
  end

  scope "/api", FountainWeb do
    pipe_through [:accepts_json, :api]

    resources "/environments", EnvironmentController, except: [:new, :edit] do
      resources "/secrets", SecretController, only: [:index, :create, :delete]
    end

    resources "/vaults", VaultController, except: [:new, :edit] do
      resources "/secrets", VaultSecretController, only: [:index, :create, :delete]
    end

    resources "/agents", AgentController, except: [:new, :edit]

    # Bulk apply for compiled fountain.yml manifests (`fountain apply`).
    post "/apply", ApplyController, :create

    resources "/conversations", ConversationController, only: [:index, :show, :create, :delete] do
      post "/prompts", ConversationController, :prompt, as: :prompt
      post "/interrupt", ConversationController, :interrupt, as: :interrupt
      post "/terminate", ConversationController, :terminate, as: :terminate
      get "/turns", ConversationController, :turns, as: :turns
      get "/turns/:turn_id/images/:position", TurnImageController, :show, as: :turn_image
    end
  end

  # Server-sent events. Same auth chain as the rest of /api, minus content
  # negotiation — see the `:api` pipeline. The action sets its own
  # `text/event-stream` content-type and its error paths go through
  # FallbackController's `json/2`, which does not consult the negotiated
  # format, so there is nothing here for `:accepts` to decide.
  scope "/api", FountainWeb do
    pipe_through :api

    get "/conversations/:conversation_id/stream", ConversationController, :stream,
      as: :conversation_stream
  end

  ## ─── Authenticated browser / LiveView routes ──────────────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through [:browser, :browser_authenticated]

    # ── Theme preference — CSRF-protected, session-authenticated ─────────────────────────────────────────
    patch "/api/settings/theme", SettingsController, :update_theme

    # ── Avatar serving — tenant-scoped image endpoint ─────────────────────────────────────────────────────
    get "/agents/:id/avatar", AgentAvatarController, :show

    # ── Account data export download — owner-scoped, expiring artifact (#288) ─────────────────────────────
    get "/account/exports/:id/download", ExportController, :download

    # ── Turn image serving — session-authenticated so <img> tags can load without a bearer token ──────────
    get "/conversations/:conversation_id/turns/:turn_id/images/:position",
        TurnImageController,
        :show

    # ── Phase-3-billing: conversation routes require an active subscription ─────────────────
    # :require_active_subscription runs after :require_authenticated_user and
    # redirects to /account/billing on SubscriptionRequiredError.
    live_session :active_subscription,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Live.Hooks, :require_active_subscription}
      ] do
      live "/conversations", ConversationsLive.Index, :index
      live "/conversations/new", ConversationsLive.New, :new
      live "/conversations/:id", ConversationsLive.Show, :show
    end

    # ── Read-only and settings routes — no subscription gate ──────────────────────────────────
    # Users can reach these routes even when past_due / canceled so they can
    # view past logs, manage resources, complete onboarding, and update payment
    # details. See decisions/0006-hard-stripe-billing-gate-at-launch.md.
    live_session :authenticated,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user}
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

      # ── Phase-3-billing: account/billing ─────────────────────────────────────────────────────
      live "/account/billing", Live.BillingLive, :index

      # ── BYO inference credentials (ADR 0008) ───────────────────────────────────────────────
      live "/account/inference-credentials", InferenceCredentialsLive.Index, :index
    end

    live_session :admin,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Live.Hooks, :require_admin}
      ] do
      live "/admin", AdminLive.Index, :index
    end
  end

  ## ─── Dev dashboard ──────────────────────────────────────────────────────────────────────────────────

  if Application.compile_env(:fountain, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser]
      live_dashboard "/dashboard", metrics: FountainWeb.Telemetry
    end
  end
end
