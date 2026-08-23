defmodule FountainWeb.AdminLive.Shell do
  @moduledoc """
  The chrome every admin page shares: a title and the tab bar that names the
  other pages.

  `/admin` used to be one LiveView rendering six stacked sections, and its
  `mount` plus its ten-second refresh re-ran every query behind all six no
  matter which one you were reading. The sections are now pages, so a page
  loads its own data and nothing else, and this module is what keeps them
  looking like one panel.

  The tabs are the whole of the admin surface at the top level. The detail
  pages beneath them (`/admin/users/:id`, `/admin/conversations/:id`) render
  the same bar with `current` set to the section they belong to, so an
  operator who drilled in can still see where they are and get back out.
  """

  use Phoenix.Component
  use FountainWeb, :verified_routes

  @doc """
  Header for an admin page: an `<h1>`, an optional one-line description, and
  the tab bar.

  `current` is the tab to mark, as an atom. Pass the section a detail page
  belongs to rather than nothing, so the bar still highlights.
  """
  attr :title, :string, required: true
  attr :current, :atom, required: true
  attr :billing_enabled, :boolean, default: false
  slot :subtitle
  slot :actions

  def admin_header(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold">{@title}</h1>
          <p :if={@subtitle != []} class="text-sm text-zinc-500 mt-1">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>

      <.admin_tabs current={@current} billing_enabled={@billing_enabled} />
    </div>
    """
  end

  @doc """
  The tab bar on its own, for a page that builds its own header (a detail
  page titles itself with the record it is showing).
  """
  attr :current, :atom, required: true
  attr :billing_enabled, :boolean, default: false

  def admin_tabs(assigns) do
    assigns = assign(assigns, :tabs, tabs(assigns.billing_enabled))

    ~H"""
    <nav
      class="flex flex-wrap items-center gap-1 border-b border-zinc-200 -mb-px"
      aria-label="Admin sections"
    >
      <.link
        :for={{key, label, path} <- @tabs}
        navigate={path}
        aria-current={if key == @current, do: "page"}
        class={[
          "px-3 py-2 text-sm border-b-2 -mb-px transition-colors",
          if(key == @current,
            do: "border-zinc-900 text-zinc-900 font-medium",
            else: "border-transparent text-zinc-500 hover:text-zinc-900 hover:border-zinc-300"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end

  # Finance and Billing are two pages because they answer two questions.
  # Billing is the state of the Stripe integration — who is on what status,
  # which webhooks are failing. Finance is the money. Both are hidden on a
  # deployment with billing off, where neither has anything to say.
  defp tabs(billing_enabled) do
    billing =
      if billing_enabled do
        [
          {:billing, "Billing", ~p"/admin/billing"},
          {:finance, "Finance", ~p"/admin/finance"}
        ]
      else
        []
      end

    [
      {:overview, "Overview", ~p"/admin"},
      {:users, "Users", ~p"/admin/users"},
      {:sandboxes, "Sandboxes", ~p"/admin/sandboxes"}
    ] ++ billing ++ [{:activity, "Activity", ~p"/admin/activity"}]
  end
end
