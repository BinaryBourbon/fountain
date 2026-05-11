defmodule FountainWeb.Layouts do
  use FountainWeb, :html

  embed_templates "layouts/*"

  alias Fountain.Conversations

  def app(assigns) do
    convs =
      case assigns[:current_user] do
        %{id: user_id} ->
          try do
            Conversations.list_conversations_by_activity(user_id)
          rescue
            _ -> []
          end

        _ ->
          []
      end

    assigns = assign(assigns, :nav_conversations, convs)

    ~H"""
    <div class="min-h-screen bg-[var(--color-bg-0)] text-[var(--color-text-primary)]">
      <.flash_group flash={@flash} />

      <%!-- Layout wrapper — peer checkbox drives mobile sidebar --%>
      <div class="flex relative">
        <input
          type="checkbox"
          id="sidebar-toggle"
          class="peer sr-only"
          aria-label="Toggle navigation"
        />

        <%!-- Mobile backdrop (visible when sidebar open) --%>
        <label
          for="sidebar-toggle"
          class="peer-checked:block hidden fixed inset-0 z-30 bg-black/50 md:hidden cursor-pointer"
          aria-hidden="true"
        />

        <%!-- Sidebar --%>
        <aside
          id="app-sidebar"
          class="fixed md:sticky top-0 inset-y-0 left-0 z-40
                 flex flex-col w-56 h-screen
                 border-r border-[var(--color-border)] bg-[var(--color-bg-1)]
                 -translate-x-full peer-checked:translate-x-0 md:translate-x-0
                 transition-transform duration-200"
        >
          <%!-- Sidebar header --%>
          <div class="flex items-center justify-between p-4 border-b border-[var(--color-border)] shrink-0">
            <.link navigate={~p"/conversations"} class="flex items-center gap-2">
              <img src="/images/app-icon.png" alt="" class="size-7 rounded-md" />
              <span class="font-semibold text-sm text-[var(--color-text-primary)]">Fountain</span>
            </.link>
            <%!-- Mobile close button --%>
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

          <%!-- Primary nav --%>
          <nav
            class="px-2 pt-3 pb-1 text-sm space-y-0.5 shrink-0"
            aria-label="Primary navigation"
          >
            <.nav_link href={~p"/conversations"} label="Conversations" current={@current_path} />
            <.nav_link href={~p"/agents"} label="Agents" current={@current_path} />
            <.nav_link href={~p"/environments"} label="Environments" current={@current_path} />
            <.nav_link href={~p"/vaults"} label="Vaults" current={@current_path} />
          </nav>

          <%!-- Recent conversations (scrollable) --%>
          <div class="flex-1 min-h-0 overflow-y-auto px-2 py-1">
            <div :if={@nav_conversations != []}>
              <p class="px-3 py-1 text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium">
                Recent
              </p>
              <.conv_nav_link
                :for={conv <- @nav_conversations}
                conv={conv}
                current={@current_path}
              />
            </div>
          </div>

          <%!-- Settings section --%>
          <div class="border-t border-[var(--color-border)] px-2 py-2 space-y-0.5 shrink-0">
            <p class="px-3 pt-1 pb-0.5 text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium">
              Settings
            </p>
            <.nav_link href={~p"/api-keys"} label="API Keys" current={@current_path} />
            <.nav_link
              href={~p"/account/billing"}
              label="Billing"
              current={@current_path}
            />
            <.nav_link href={~p"/audit"} label="Audit log" current={@current_path} />
            <.nav_link href={~p"/help"} label="Help" current={@current_path} />
            <.nav_link
              :if={assigns[:current_user] && assigns.current_user.role == "admin"}
              href={~p"/admin"}
              label="Admin"
              current={@current_path}
            />
          </div>

          <%!-- Sidebar footer: user email, theme toggle, sign-out --%>
          <div class="border-t border-[var(--color-border)] px-3 py-3 shrink-0">
            <div class="flex items-center justify-between gap-2">
              <div class="min-w-0 flex-1">
                <p
                  :if={assigns[:current_user]}
                  class="text-xs font-medium text-[var(--color-text-primary)] truncate"
                >
                  {assigns.current_user.email}
                </p>
                <a
                  href={~p"/auth/logout"}
                  data-method="post"
                  class="text-xs text-[var(--color-text-secondary)] hover:text-[var(--color-text-primary)] transition-colors"
                >
                  Sign out
                </a>
              </div>
              <%!-- Theme toggle --%>
              <button
                id="theme-toggle"
                phx-hook="ThemeToggle"
                type="button"
                aria-label="Toggle dark mode"
                class="shrink-0 rounded-md p-1.5 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-focus-ring)]"
              >
                <%!-- Moon icon (shown in light mode — click to go dark) --%>
                <svg
                  id="theme-icon-moon"
                  class="size-4"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  aria-hidden="true"
                >
                  <path d="M17.293 13.293A8 8 0 0 1 6.707 2.707a8.001 8.001 0 1 0 10.586 10.586z" />
                </svg>
                <%!-- Sun icon (hidden by default; shown in dark mode) --%>
                <svg
                  id="theme-icon-sun"
                  class="size-4 hidden"
                  viewBox="0 0 20 20"
                  fill="currentColor"
                  aria-hidden="true"
                >
                  <path
                    fill-rule="evenodd"
                    d="M10 2a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0V3a1 1 0 0 1 1-1Zm4 8a4 4 0 1 1-8 0 4 4 0 0 1 8 0Zm-.464 4.95.707.707a1 1 0 0 0 1.414-1.414l-.707-.707a1 1 0 0 0-1.414 1.414Zm2.12-10.607a1 1 0 0 1 0 1.414l-.706.707a1 1 0 1 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 0ZM17 11a1 1 0 1 0 0-2h-1a1 1 0 1 0 0 2h1Zm-7 4a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0v-1a1 1 0 0 1 1-1ZM5.05 6.464A1 1 0 1 0 6.465 5.05l-.708-.707a1 1 0 0 0-1.414 1.414l.707.707Zm1.414 8.486-.707.707a1 1 0 0 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 1.414ZM4 11a1 1 0 1 0 0-2H3a1 1 0 0 0 0 2h1Z"
                    clip-rule="evenodd"
                  />
                </svg>
              </button>
            </div>
          </div>
        </aside>

        <%!-- Main content area --%>
        <div class="flex-1 min-w-0 flex flex-col">
          <%!-- Mobile top bar --%>
          <div class="md:hidden flex items-center gap-3 px-4 py-3 border-b border-[var(--color-border)] bg-[var(--color-bg-1)] sticky top-0 z-20">
            <label
              for="sidebar-toggle"
              class="cursor-pointer rounded-md p-1.5 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
              aria-label="Open navigation"
            >
              <svg
                class="size-5"
                viewBox="0 0 20 20"
                fill="currentColor"
                aria-hidden="true"
              >
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

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, default: ""

  defp nav_link(assigns) do
    active =
      (String.starts_with?(assigns.current || "", assigns.href) and assigns.href != "/") or
        assigns.current == assigns.href

    assigns = assign(assigns, :active, active)

    ~H"""
    <a
      href={@href}
      class={[
        "block rounded-md px-3 py-1.5 text-sm transition-colors",
        if(@active,
          do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-text-primary)]",
          else:
            "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"
        )
      ]}
    >
      {@label}
    </a>
    """
  end

  attr :conv, :map, required: true
  attr :current, :string, default: ""

  defp conv_nav_link(assigns) do
    href = "/conversations/#{assigns.conv.id}"
    active = assigns.current == href

    first_turn =
      case assigns.conv.turns do
        %Ecto.Association.NotLoaded{} -> nil
        turns -> List.first(turns)
      end

    task_label = if first_turn, do: truncate(first_turn.prompt, 55), else: nil
    agent_name = assigns.conv.agent && assigns.conv.agent.name

    meta =
      [agent_name, sidebar_relative_time(assigns.conv.updated_at)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    {dot_class, status_label} =
      case assigns.conv.status do
        "running" -> {"bg-[var(--status-starting-text)] animate-pulse", "running"}
        "ready" -> {"bg-[var(--status-ready-text)]", "ready"}
        "pending" -> {"bg-[var(--status-pending-text)]", "pending"}
        s -> {"bg-[var(--color-text-muted)]", s}
      end

    assigns =
      assign(assigns,
        href: href,
        active: active,
        task_label: task_label,
        meta: meta,
        dot_class: dot_class,
        status_label: status_label
      )

    ~H"""
    <a
      href={@href}
      class={[
        "flex items-start gap-2 rounded-md px-3 py-2 text-sm transition-colors",
        if(@active,
          do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-text-primary)]",
          else:
            "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"
        )
      ]}
    >
      <span
        class={["size-2 rounded-full shrink-0 mt-1.5", @dot_class]}
        title={@status_label}
      />
      <span class="flex-1 min-w-0">
        <span :if={@task_label} class="block truncate">{@task_label}</span>
        <span :if={!@task_label} class="block truncate italic text-[var(--color-text-muted)]">
          (no task yet)
        </span>
        <span
          :if={@meta != ""}
          class="block text-[11px] text-[var(--color-text-muted)] truncate mt-0.5"
        >
          {@meta}
        </span>
      </span>
    </a>
    """
  end

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) do
    text = text |> String.trim() |> String.replace(~r/\s+/, " ")
    if String.length(text) > max, do: String.slice(text, 0, max) <> "\u2026", else: text
  end

  defp sidebar_relative_time(nil), do: nil

  defp sidebar_relative_time(dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt))

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
