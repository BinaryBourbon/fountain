defmodule FountainWeb.VerifyPendingLive do
  @moduledoc """
  The waiting room for a signed-in but unverified account (#533).

  Before this page an unverified login was bounced to `/auth/login` with a
  flash, which read as a failed sign-in even though the session was fine — and
  re-entering the password never actually helped, because the emailed link logs
  the user in itself.

  ## Auto-advance

  The page watches for verification landing elsewhere — the link opened in
  another tab, or on a phone — and sends the user on without a second login:

    * `Accounts.verify_email/1` broadcasts on `Accounts.verification_topic/1`,
      which is instant; and
    * a five-second poll backstops it, because the broadcast only crosses nodes
      when BEAM clustering is actually configured (`DNS_CLUSTER_QUERY`), and a
      page that silently fails to advance is the dead end this replaced.

  Both paths re-read the user from the database rather than trusting the
  message, so the redirect is never issued on a stale assign.
  """

  use FountainWeb, :live_view

  alias Fountain.Accounts
  alias Fountain.Workers.VerificationEmail
  alias FountainWeb.Live.Hooks
  alias FountainWeb.Plugs.RateLimit

  @poll_interval_ms 5_000

  # Same budget as the `resend_verification` bucket on
  # `RegistrationController.resend`, keyed by user id rather than IP: on this
  # page we know exactly who is asking, which is both a fairer key (one office
  # NAT can't exhaust everyone's allowance) and a tighter one (a resend spammer
  # can't reset it by changing address).
  @resend_max 5
  @resend_window_ms 3_600_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Fountain.PubSub, Accounts.verification_topic(user.id))
      :timer.send_interval(@poll_interval_ms, self(), :check_verification)
    end

    socket =
      socket
      |> assign(:page_title, "Check your email")
      |> assign(:resend, :idle)

    # Re-checked after subscribing, not before: a verification landing in that
    # gap would have broadcast to nobody, and the page would wait forever.
    {:ok, advance_if_verified(socket)}
  end

  @impl true
  def handle_info({:email_verified, _user_id}, socket) do
    {:noreply, advance_if_verified(socket)}
  end

  def handle_info(:check_verification, socket) do
    {:noreply, advance_if_verified(socket)}
  end

  @impl true
  def handle_event("resend", _params, socket) do
    user = socket.assigns.current_user
    RateLimit.ensure_table()

    case RateLimit.bump({"resend_verification", user.id}, %{
           max: @resend_max,
           window_ms: @resend_window_ms
         }) do
      :ok ->
        VerificationEmail.enqueue(user)
        {:noreply, assign(socket, :resend, :sent)}

      {:limited, _retry_after_secs} ->
        {:noreply, assign(socket, :resend, :limited)}
    end
  end

  # A full-page redirect rather than push_navigate: the destination lives in a
  # different live_session, which live navigation cannot cross.
  defp advance_if_verified(socket) do
    case Accounts.get_user(socket.assigns.current_user.id) do
      %{email_verified_at: %DateTime{}} = user ->
        redirect(socket, to: Hooks.verified_destination(user))

      _ ->
        socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <div class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-5 text-center">
        <div class="flex justify-center">
          <svg
            class="w-8 h-8 animate-spin text-zinc-400"
            viewBox="0 0 24 24"
            fill="none"
            aria-hidden="true"
          >
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
            />
          </svg>
        </div>

        <div class="space-y-2">
          <h1 class="text-xl font-semibold">Check your email</h1>
          <p class="text-sm text-zinc-600">
            We sent a verification link to <span class="font-medium text-zinc-900">{@current_user.email}</span>. Open it and this
            page will continue on its own — you're already signed in, so there's nothing else to
            type here.
          </p>
          <p class="text-xs text-zinc-400">
            Links expire after 24 hours. Nothing in your inbox? Check the spam folder.
          </p>
        </div>

        <div :if={@resend == :sent} class="rounded bg-emerald-50 text-emerald-700 px-3 py-2 text-sm">
          A fresh verification link is on its way.
        </div>

        <div :if={@resend == :limited} class="rounded bg-amber-50 text-amber-700 px-3 py-2 text-sm">
          That's a lot of resends. Wait a little while before trying again.
        </div>

        <div class="space-y-2">
          <button
            type="button"
            phx-click="resend"
            class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800"
          >
            Resend verification email
          </button>

          <p class="text-xs text-zinc-400">
            Signed up with the wrong address?
            <.link href={~p"/auth/logout"} class="underline">Sign out</.link>
            and start again.
          </p>
        </div>
      </div>
    </div>
    """
  end
end
