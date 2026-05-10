defmodule FountainWeb.SessionHTML do
  use FountainWeb, :html

  def new(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-50 text-zinc-900 font-sans">
      <form method="post" action={~p"/login"} class="w-full max-w-sm bg-white rounded-lg shadow p-8 space-y-4">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <div>
          <h1 class="text-xl font-semibold">Agent on Demand</h1>
          <p class="text-sm text-zinc-500">Enter your admin token to continue.</p>
        </div>
        <div :if={@error} class="rounded bg-rose-50 text-rose-700 px-3 py-2 text-sm">{@error}</div>
        <input type="password" name="token" placeholder="ADMIN_TOKEN" autofocus
          class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-zinc-400"/>
        <button type="submit" class="w-full rounded-md bg-zinc-900 text-white py-2 text-sm font-medium hover:bg-zinc-800">Sign in</button>
      </form>
    </div>
    """
  end
end
