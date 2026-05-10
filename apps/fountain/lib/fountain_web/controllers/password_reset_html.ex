defmodule FountainWeb.PasswordResetHTML do
  use FountainWeb, :html

  def forgot_form(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <form method="post" action={~p"/api/auth/forgot"} class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <div>
          <h1 class="text-xl font-semibold">Reset your password</h1>
          <p class="text-sm text-zinc-500">
            Enter your email and we'll send you a reset link.
          </p>
        </div>
        <input
          type="email"
          name="email"
          placeholder="you@example.com"
          autocomplete="email"
          autofocus
          class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
        />
        <button
          type="submit"
          class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800"
        >
          Send reset link
        </button>
        <p class="text-center text-sm text-zinc-400">
          <a href={~p"/auth/login"} class="underline">Back to sign in</a>
        </p>
      </form>
    </div>
    """
  end

  def reset_form(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <form method="post" action={~p"/auth/reset"} class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <input type="hidden" name="token" value={@token} />
        <div>
          <h1 class="text-xl font-semibold">Set a new password</h1>
          <p class="text-sm text-zinc-500">Choose a password with at least 8 characters.</p>
        </div>
        <div :if={@error} class="rounded bg-rose-50 text-rose-700 px-3 py-2 text-sm">{@error}</div>
        <input
          type="password"
          name="password"
          placeholder="New password (8+ characters)"
          autocomplete="new-password"
          autofocus
          class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-400"
        />
        <button
          type="submit"
          class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800"
        >
          Update password
        </button>
      </form>
    </div>
    """
  end
end
