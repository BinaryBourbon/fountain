defmodule FountainWeb.Live.Hooks do
  @moduledoc """
  LiveView `on_mount` hooks for multi-tenant authentication and billing.

  ## Usage in router live_session

      live_session :authenticated,
        on_mount: [{FountainWeb.Live.Hooks, :require_authenticated_user}] do
        live "/dashboard", DashboardLive, :index
      end

      live_session :active_subscription,
        on_mount: [
          {FountainWeb.Live.Hooks, :require_authenticated_user},
          {FountainWeb.Live.Hooks, :require_active_subscription}
        ] do
        live "/", ConversationsLive.Index, :index
      end

  ## Hooks

  - `:require_authenticated_user` — halts and redirects to login if no
    current_user is set, or to `/auth/verify-pending` if the user's email is
    unverified.
  - `:require_pending_verification` — the inverse gate, for the waiting page
    itself: requires a session but tolerates an unverified one, and bounces
    already-verified users to where they belong so the page can't be camped on.
  - `:require_active_subscription` — halts and redirects to `/account/billing`
    if the user's subscription is `past_due` or `canceled`. Must run after
    `:require_authenticated_user` (current_user must already be assigned).
  - `:require_admin` — halts if current_user is absent or not an admin.
    Unauthenticated users are redirected to login (HTTP redirect). Authenticated
    non-admin users are redirected to /dashboard (live redirect).
  - `:assign_subscription_state` — never halts; assigns `@subscription_active`
    so read-only-capable views (#505: conversation list/detail) can render for
    past_due/canceled users while disabling what would spend. Must run after
    `:require_authenticated_user`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  use FountainWeb, :verified_routes

  alias Fountain.Accounts
  alias Fountain.Billing
  alias Fountain.Conversations

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      # Not the login form (#533): the session is valid and the password was
      # right, so bouncing them there reads as a failed login and invites a
      # second, pointless sign-in. The waiting page explains the real state.
      is_nil(user.email_verified_at) ->
        {:halt, redirect(socket, to: ~p"/auth/verify-pending")}

      true ->
        {:cont,
         socket
         |> FountainWeb.Audited.put_client_ip()
         |> track_current_path()
         |> mount_live_sidebar()}
    end
  end

  def on_mount(:require_pending_verification, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      is_nil(user.email_verified_at) ->
        {:cont, socket}

      # Already verified — nothing to wait for. Without this the page would be
      # a dead end anyone could sit on after finishing verification.
      true ->
        {:halt, redirect(socket, to: verified_destination(user))}
    end
  end

  def on_mount(:require_active_subscription, _params, _session, socket) do
    user = socket.assigns[:current_user]

    try do
      Billing.assert_active!(user)
      {:cont, socket}
    rescue
      Billing.SubscriptionRequiredError ->
        {:halt,
         socket
         |> put_flash(
           :error,
           "Your subscription requires attention. Please update your payment method."
         )
         |> redirect(to: ~p"/account/billing")}
    end
  end

  def on_mount(:assign_subscription_state, _params, _session, socket) do
    active = Billing.check_active(socket.assigns.current_user) == :ok
    {:cont, assign(socket, :subscription_active, active)}
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      user.role != "admin" ->
        {:halt, push_navigate(socket, to: ~p"/dashboard")}

      true ->
        {:cont, socket}
    end
  end

  @doc """
  Where a verified user belongs: onboarding until it is finished, the
  conversation list after.

  Public so `FountainWeb.VerifyPendingLive` sends users to the same place
  `:require_pending_verification` does — the page and the gate that guards it
  must not disagree, or the two bounce off each other.
  """
  def verified_destination(%{onboarding_completed_at: nil}), do: ~p"/onboarding/step_1"
  def verified_destination(_user), do: ~p"/conversations"

  # Mount current_user from session into socket assigns without hitting the
  # DB a second time if it was already assigned (e.g. from a previous hook).
  defp mount_current_user(session, socket) do
    assign_new(socket, :current_user, fn ->
      user_id = Map.get(session, "user_id")
      session_version = Map.get(session, "session_version")

      with true <- is_binary(user_id),
           true <- is_integer(session_version),
           %Accounts.User{} = user <- Accounts.get_user(user_id),
           true <- user.session_version == session_version do
        user
      else
        _ -> nil
      end
    end)
  end

  # The shared layout reads @current_path to highlight the active nav item.
  # Seed it with "/" for the initial render and update it from the URI on
  # every handle_params (LiveView navigation).
  defp track_current_path(socket) do
    socket
    |> assign_new(:current_path, fn -> "/" end)
    |> Phoenix.LiveView.attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
      {:cont, assign(socket, :current_path, URI.parse(uri).path)}
    end)
  end

  # Subscribe to the user's sidebar PubSub topic and load the initial
  # conversation list into socket assigns. A handle_info hook intercepts
  # {:sidebar_update, user_id} messages and refreshes nav_conversations
  # in-place, so the sidebar re-renders without any per-LiveView code.
  #
  # A handle_event hook intercepts the two sidebar filter events
  # (sidebar_toggle_roots_only, sidebar_set_agent_filter) so they never
  # reach — and confuse — the current LiveView's own handle_event.
  #
  # sidebar_roots_only is initialised from user.conversations_roots_only (DB)
  # so the sidebar renders the correct filter state on the very first paint,
  # with no localStorage round-trip. The toggle also persists back to DB.
  defp mount_live_sidebar(socket) do
    user = socket.assigns.current_user
    user_id = user.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user_id}")
    end

    socket
    |> assign(:nav_conversations, load_sidebar_conversations(user_id))
    |> assign(:sidebar_roots_only, user.conversations_roots_only)
    |> assign(:sidebar_agent_filter, nil)
    |> attach_hook(:sidebar_nav, :handle_info, fn
      {:sidebar_update, ^user_id}, socket ->
        {:halt, assign(socket, :nav_conversations, load_sidebar_conversations(user_id))}

      _, socket ->
        {:cont, socket}
    end)
    |> attach_hook(:sidebar_filters, :handle_event, fn
      "restore_roots_only", _params, socket ->
        {:halt, assign(socket, :sidebar_roots_only, true)}

      "sidebar_toggle_roots_only", _params, socket ->
        next = !socket.assigns.sidebar_roots_only
        Accounts.update_preferences(socket.assigns.current_user, %{conversations_roots_only: next})

        {:halt,
         socket
         |> assign(:sidebar_roots_only, next)
         |> push_event("roots_only_changed", %{value: to_string(next)})}

      "sidebar_set_agent_filter", %{"agent_id" => agent_id}, socket ->
        filter = if agent_id == "", do: nil, else: agent_id
        {:halt, assign(socket, :sidebar_agent_filter, filter)}

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  defp load_sidebar_conversations(user_id) do
    try do
      Conversations.list_conversations_by_activity(user_id)
    rescue
      _ -> []
    end
  end
end
