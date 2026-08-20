defmodule FountainWeb.Layouts do
  @moduledoc """
  The console's chrome.

  Fountain's own UI is an operator console: the account and its keys, and the
  three primitives a conversation runs on. Watching an agent work and
  messaging a teammate happen in the apps this sidebar links out to
  (`Fountain.Apps`), which is why there is no conversation list in here any
  more (#867).
  """
  use FountainWeb, :html

  embed_templates "layouts/*"

  def app(assigns) do
    footer_open =
      Enum.any?(
        ["/api-keys", "/account", "/audit", "/help", "/admin"],
        &String.starts_with?(assigns[:current_path] || "", &1)
      )

    assigns =
      assign(assigns,
        footer_open: footer_open,
        conversations_app: Fountain.Apps.conversations(),
        team_app: Fountain.Apps.team()
      )

    ~H"""
    <div class="min-h-screen bg-[var(--color-bg-0)] text-[var(--color-text-primary)]">
      <.flash_group flash={@flash} />

      <div class="flex relative">
        <input
          type="checkbox"
          id="sidebar-toggle"
          class="peer sr-only"
          aria-label="Toggle navigation"
        />

        <label
          for="sidebar-toggle"
          class="peer-checked:block hidden fixed inset-0 z-30 bg-black/50 md:hidden cursor-pointer"
          aria-hidden="true"
        />

        <aside
          id="app-sidebar"
          class="fixed md:sticky top-0 inset-y-0 left-0 z-40
                 flex flex-col w-72 h-screen
                 border-r border-[var(--color-border)] bg-[var(--color-bg-1)]
                 -translate-x-full peer-checked:translate-x-0 md:translate-x-0
                 transition-transform duration-200"
        >
          <%!-- Sidebar header --%>
          <div class="flex items-center justify-between p-4 border-b border-[var(--color-border)] shrink-0">
            <.link href={~p"/dashboard"} class="flex items-center gap-2">
              <img src="/images/app-icon.png" alt="" class="size-7 rounded-md" />
              <span class="font-semibold text-sm text-[var(--color-text-primary)]">Fountain</span>
            </.link>
            <label
              for="sidebar-toggle"
              class="md:hidden cursor-pointer rounded-md p-1 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
              aria-label="Close navigation"
            >
              <svg class="size-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
              </svg>
            </label>
          </div>

          <%!-- Primary nav: the primitives a conversation runs on --%>
          <nav class="px-2 pt-2 pb-1 text-sm space-y-0.5 shrink-0" aria-label="Primary navigation">
            <.nav_link href={~p"/dashboard"} label="Dashboard" current={@current_path} />
            <.nav_link href={~p"/agents"} label="Agents" current={@current_path} />
            <.nav_link href={~p"/environments"} label="Environments" current={@current_path} />
            <.nav_link href={~p"/vaults"} label="Vaults" current={@current_path} />
          </nav>

          <%!-- The apps on top of the API. External: they are their own
                origins, and a deployment may have neither. --%>
          <div
            :if={@conversations_app || @team_app}
            class="border-t border-[var(--color-border)] px-2 py-1.5 space-y-0.5 shrink-0"
          >
            <p class="px-3 pt-1 pb-0.5 text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium">
              Apps
            </p>
            <.app_link :if={@conversations_app} href={@conversations_app} label="Conversations" />
            <.app_link :if={@team_app} href={@team_app} label="Team" />
          </div>

          <div class="flex-1 min-h-0" />

          <%!-- Sidebar footer: click username to reveal settings --%>
          <div class="border-t border-[var(--color-border)] shrink-0 flex items-start">
            <details class="flex-1 min-w-0 group" open={@footer_open}>
              <summary class="
                flex items-center gap-2 px-3 py-2.5
                cursor-pointer select-none
                list-none [&::-webkit-details-marker]:hidden
                hover:bg-[var(--color-bg-2)] transition-colors
              ">
                <span
                  :if={assigns[:current_user]}
                  class="flex-1 min-w-0 text-xs font-medium text-[var(--color-text-primary)] truncate"
                >
                  {assigns.current_user.email}
                </span>
                <svg
                  class="size-3.5 shrink-0 text-[var(--color-text-muted)] -rotate-90 group-open:rotate-0 transition-transform duration-150"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  aria-hidden="true"
                >
                  <path
                    fill-rule="evenodd"
                    d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z"
                    clip-rule="evenodd"
                  />
                </svg>
              </summary>
              <div class="px-2 pt-0.5 pb-2 space-y-0.5 border-t border-[var(--color-border)]">
                <.nav_link href={~p"/account"} label="Account" current={@current_path} exact />
                <.nav_link href={~p"/api-keys"} label="API Keys" current={@current_path} />
                <.nav_link href={~p"/account/runners"} label="Runners" current={@current_path} />
                <.nav_link
                  :if={Fountain.Billing.enabled?()}
                  href={~p"/account/billing"}
                  label="Billing"
                  current={@current_path}
                />
                <.nav_link href={~p"/account/security"} label="Security" current={@current_path} />
                <.nav_link href={~p"/audit"} label="Audit log" current={@current_path} />
                <.nav_link href={~p"/help"} label="Help" current={@current_path} />
                <.nav_link
                  :if={assigns[:current_user] && assigns.current_user.role == "admin"}
                  href={~p"/admin"}
                  label="Admin"
                  current={@current_path}
                />
                <a
                  href={~p"/auth/logout"}
                  class="block rounded-md px-3 py-1 text-sm text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors"
                >
                  Sign out
                </a>
                <p class="px-3 pt-2 text-[10px] font-mono text-[var(--color-text-muted)] select-text">
                  {build_version()}
                </p>
              </div>
            </details>
            <button
              id="theme-toggle"
              phx-hook="ThemeToggle"
              type="button"
              aria-label="Toggle dark mode"
              class="shrink-0 mt-1 mr-1.5 rounded-md p-1.5 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-focus-ring)]"
            >
              <svg
                id="theme-icon-moon"
                class="size-4"
                viewBox="0 0 20 20"
                fill="currentColor"
                aria-hidden="true"
              >
                <path d="M17.293 13.293A8 8 0 0 1 6.707 2.707a8.001 8.001 0 1 0 10.586 10.586z" />
              </svg>
              <svg
                id="theme-icon-sun"
                class="size-4 hidden"
                viewBox="0 0 20 20"
                fill="currentColor"
                aria-hidden="true"
              >
                <path
                  fill-rule="evenodd"
                  d="M10 2a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0V3a1 1 0 0 1 1-1Zm4 8a4 4 0 1 1-8 0 4 4 0 0 1 8 0Zm-.464 4.95.707.707a1 1 0 0 0 1.414-1.414l-.707-.707a1 1 0 0 0-1.414 1.414Zm2.12-10.607a1 1 0 0 1 0 1.414l-.706.707a1 1 0 1 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 0ZM17 11a1 1 0 1 0 0-2h-1a1 1 0 1 1 0 2h1Zm-7 4a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0v-1a1 1 0 0 1 1-1ZM5.05 6.464A1 1 0 1 0 6.465 5.05l-.708-.707a1 1 0 0 0-1.414 1.414l.707.707Zm1.414 8.486-.707.707a1 1 0 0 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 1.414ZM4 11a1 1 0 1 0 0-2H3a1 1 0 0 0 0 2h1Z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
          </div>
        </aside>

        <%!-- Main content area --%>
        <div class="flex-1 min-w-0 flex flex-col">
          <div class="md:hidden flex items-center gap-3 px-4 py-3 border-b border-[var(--color-border)] bg-[var(--color-bg-1)] sticky top-0 z-20">
            <label
              for="sidebar-toggle"
              class="cursor-pointer rounded-md p-1.5 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
              aria-label="Open navigation"
            >
              <svg class="size-5" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path
                  fill-rule="evenodd"
                  d="M2 4.75A.75.75 0 0 1 2.75 4h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 4.75ZM2 10a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 10Zm0 5.25a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1-.75-.75Z"
                  clip-rule="evenodd"
                />
              </svg>
            </label>
            <span class="font-semibold text-sm text-[var(--color-text-primary)]">Fountain</span>
          </div>

          <main class="flex-1 p-6">
            {@inner_content}
          </main>
        </div>
      </div>
    </div>
    """
  end

  # Deployment marker shown under the sidebar email popup. Combines the
  # umbrella app version with the short git SHA the Docker image was
  # built from. `FOUNTAIN_BUILD_SHA` is set in the runtime image via a
  # docker build-arg wired up in .github/workflows/build.yml; local dev
  # falls back to "dev".
  defp build_version do
    vsn = :fountain |> Application.spec(:vsn) |> to_string()
    sha = "FOUNTAIN_BUILD_SHA" |> System.get_env("dev") |> String.slice(0, 7)
    "v#{vsn} · #{sha}"
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  # An app on its own origin: a plain <a>, and said so, because it leaves
  # Fountain's session behind and signs in with its own token.
  defp app_link(assigns) do
    ~H"""
    <a
      href={@href}
      class="flex items-center gap-1.5 rounded-md px-3 py-1 text-sm text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors"
    >
      {@label}
      <svg
        class="size-3 shrink-0 opacity-60"
        viewBox="0 0 20 20"
        fill="currentColor"
        aria-hidden="true"
      >
        <path d="M11 3a1 1 0 1 0 0 2h2.586l-6.293 6.293a1 1 0 1 0 1.414 1.414L15 6.414V9a1 1 0 1 0 2 0V4a1 1 0 0 0-1-1h-5Z" />
        <path d="M5 5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-3a1 1 0 1 0-2 0v3H5V7h3a1 1 0 0 0 0-2H5Z" />
      </svg>
    </a>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, default: ""
  # Highlight only on an exact path match — for links like /account whose
  # href is a prefix of sibling pages (/account/billing, /account/security).
  attr :exact, :boolean, default: false

  defp nav_link(assigns) do
    active =
      if assigns.exact do
        assigns.current == assigns.href
      else
        (String.starts_with?(assigns.current || "", assigns.href) and assigns.href != "/") or
          assigns.current == assigns.href
      end

    assigns = assign(assigns, active: active, link_attrs: [href: assigns.href])

    ~H"""
    <.link
      {@link_attrs}
      class={[
        "block rounded-md px-3 py-1 text-sm transition-colors",
        if(@active,
          do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-text-primary)]",
          else:
            "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end
end
