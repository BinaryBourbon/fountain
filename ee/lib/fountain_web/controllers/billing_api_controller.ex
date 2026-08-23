defmodule FountainWeb.BillingApiController do
  @moduledoc """
  Billing self-serve over the API (#524).

  All user-facing billing lived in `BillingLive`: the usage summary, Checkout
  session minting, Portal session minting. `GET /api/auth/me` exposed
  `subscription_status` and nothing else, so a CLI user who hit the
  subscription gate got a 402 with no programmatic way out of it.

  Stripe requires a browser to finish, so URLs are the deliverable — this mints
  them, the user opens them. Return URLs are server-chosen on purpose: a
  caller-supplied one would be an open redirect wearing a Stripe badge.

  Lives in `ee/` with the rest of billing (#472).
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Billing
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Billing"])

  operation(:show,
    summary: "Subscription status and current-period usage",
    description:
      "Trial and period dates alongside the usage numbers the billing page " <>
        "shows, measured over the period Stripe invoices where one is known " <>
        "and the calendar month otherwise (`period.source` says which). " <>
        "On an instance with billing disabled this is a 404 carrying " <>
        "`billing: \"disabled\"`, mirroring the UI, which redirects away from " <>
        "the billing page entirely.",
    responses: [
      ok: {"Billing", "application/json", Schemas.BillingResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Billing disabled", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    with :ok <- require_billing() do
      user = conn.assigns.current_user
      period = Billing.billing_period(user)

      render(conn, :show,
        user: user,
        usage: Billing.usage_summary(user.id, period.start, period.end),
        allowance: Billing.turn_hour_allowance(user, period: period),
        period: period
      )
    end
  end

  operation(:portal,
    summary: "Mint a Stripe Billing Portal URL",
    description:
      "Where an existing customer manages payment methods, invoices and " <>
        "cancellation. Refused for a comped account and for an account that has " <>
        "never been a Stripe customer.",
    responses: [
      ok: {"Stripe URL", "application/json", Schemas.StripeUrlResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Billing disabled", "application/json", Schemas.Error},
      unprocessable_entity: {"Nothing to manage", "application/json", Schemas.Error},
      bad_gateway: {"Stripe unreachable", "application/json", Schemas.Error}
    ]
  )

  def portal(conn, _params) do
    with :ok <- require_billing() do
      conn.assigns.current_user
      |> Billing.portal_url(return_url())
      |> render_url(conn)
    end
  end

  operation(:checkout,
    summary: "Mint a Stripe Checkout URL",
    description:
      "Starts a subscription. Refused for a comped account, and refused with " <>
        "`subscription_exists` when Stripe already holds a live subscription — " <>
        "Checkout on top of one creates a second, duplicate subscription. Use " <>
        "the portal endpoint in that case. `plan` names the tier to buy; " <>
        "omit it for this deployment's default.",
    parameters: [
      plan: [
        in: :query,
        # Public slugs only: `legacy` is a closed price nobody can buy, and
        # publishing it here would advertise a value Checkout cannot honour.
        type: %OpenApiSpex.Schema{type: :string, enum: Fountain.Plans.public_slugs()},
        required: false,
        description: "Plan slug to subscribe to."
      ]
    ],
    responses: [
      ok: {"Stripe URL", "application/json", Schemas.StripeUrlResponse},
      conflict: {"Live subscription exists", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Billing disabled", "application/json", Schemas.Error},
      unprocessable_entity: {"Comped", "application/json", Schemas.Error},
      bad_gateway: {"Stripe unreachable", "application/json", Schemas.Error}
    ]
  )

  def checkout(conn, params) do
    user = conn.assigns.current_user

    with :ok <- require_billing(),
         {:ok, false} <- live_subscription(user) do
      user
      |> Billing.checkout_url(return_url(), params["plan"])
      |> render_url(conn)
    else
      {:ok, true} ->
        # The duplicate-subscription trap the LiveView routes around silently.
        # An API caller asked for Checkout specifically, so say why it is the
        # wrong door rather than quietly handing back a Portal URL.
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "subscription_exists",
          message:
            "This account already has a live subscription in Stripe. " <>
              "Use POST /api/account/billing/portal to manage it."
        })

      {:error, :stripe_unreachable} ->
        stripe_unreachable(conn)

      other ->
        other
    end
  end

  ## Private

  defp require_billing do
    if Billing.enabled?(), do: :ok, else: {:error, :billing_disabled}
  end

  defp live_subscription(user) do
    case Billing.has_live_subscription?(user) do
      {:ok, live?} -> {:ok, live?}
      # Never guess: opening Checkout on an unknown state is what mints a
      # duplicate subscription.
      {:error, _reason} -> {:error, :stripe_unreachable}
    end
  end

  defp render_url({:ok, url}, conn), do: render(conn, :url, url: url)

  defp render_url({:error, :comped}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "comped",
      message: "This account is comped — there is nothing to pay and nothing to manage."
    })
  end

  defp render_url({:error, :no_customer}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "no_stripe_customer",
      message:
        "This account has never been a Stripe customer, so it has no portal. " <>
          "Start a subscription at POST /api/account/billing/checkout."
    })
  end

  defp render_url({:error, _reason}, conn), do: stripe_unreachable(conn)

  defp stripe_unreachable(conn) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "stripe_unreachable", message: "Could not reach Stripe. Try again."})
  end

  defp return_url, do: FountainWeb.Endpoint.url() <> "/account/billing"
end
