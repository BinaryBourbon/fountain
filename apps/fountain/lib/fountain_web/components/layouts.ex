defmodule FountainWeb.Layouts do
  @moduledoc false
  use FountainWeb, :html

  embed_templates "layouts/*"

  alias Fountain.Conversations

  # Initials and Tailwind chip classes per agent name slug.
  # If two roles collide on initials, disambiguate here rather than
  # algorithmically — keeps display stable as agents are added.
  @role_styles %{
    "general-purpose-engineer" => {"GE", "bg-sky-500/20 text-sky-600"},
    "pr-reviewer"              => {"PR", "bg-violet-500/20 text-violet-600"},
    "captain-picard"           => {"CP", "bg-amber-500/20 text-amber-700"},
    "customer-researcher"      => {"CR", "bg-teal-500/20 text-teal-600"},
    "designer"                 => {"DE", "bg-rose-500/20 text-rose-600"},
    "growth-marketer"          => {"GM", "bg-emerald-500/20 text-emerald-700"}
  }

  # Regex patterns applied in sequence to strip leading boilerplate from a
  # first-turn prompt before showing it as the sidebar title.
  # Note: \x23 is # (hex 0x23) — avoids #{} interpolation in ~r sigil.
  @strip_regexes [
    # "You are a/an [role description]. " — agent role preamble sentence
    ~r/\AYou are (?:a |an )[^.!]+[.!]\s*/,
    # "## Heading\n" — markdown section header (1-6 hashes)
    ~r/\A(?:\x23){1,6}[^\S\n]+[^\n]+\n+/,
    # Lines of key=value pairs at start (e.g. repo_url=... branch=... )
    ~r/\A(?:[a-z_][a-z0-9_]*=[^\n]+\n)+\n*/
  ]

  def app(assigns) do
    convs =
      case assigns[:nav_conversations] do
        convs when is_list(convs) ->
          convs

        _ ->
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
      end

    roots_only = Map.get(assigns, :sidebar_roots_only, false)
    agent_filter = Map.get(assigns, :sidebar_agent_filter, nil)

    unique_agents =
      convs
      |> Enum.map(& &1.agent)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.name)

    # child_counts always uses the full unfiltered list so badges stay correct
    # regardless of which filters are active.
    child_counts =
      convs
      |> Enum.map(& &1.parent_conversation_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    filtered_convs =
      convs
      |> then(fn cs ->
        if roots_only, do: Enum.filter(cs, &is_nil(&1.parent_conversation_id)), else: cs
      end)
      |> then(fn cs ->
        if agent_filter, do: Enum.filter(cs, &(&1.agent_id == agent_filter)), else: cs
      end)

    groups = group_conversations_by_date(filtered_convs)

    footer_open =
      Enum.any?(
        ["/api-keys", "/account/billing", "/audit", "/help", "/admin"],
        &String.starts_with?(assigns[:current_path] || "", &1)
      )

    assigns =
      assign(assigns,
        nav_conversations: convs,
        nav_conversation_groups: groups,
        child_counts: child_counts,
        sidebar_roots_only: roots_only,
        sidebar_agent_filter: agent_filter,
        sidebar_unique_agents: unique_agents,
        footer_open: footer_open
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
            <.link navigate={~p"/conversations"} class="flex items-center gap-2">
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

          <%!-- Primary nav --%>
          <nav
            class="px-2 pt-1 pb-0.5 text-sm space-y-0.5 shrink-0"
            aria-label="Primary navigation"
          >
            <.nav_link href={~p"/conversations"} label="Conversations" current={@current_path} />
          </nav>

          <%!-- New conversation --%>
          <div class="px-2 pb-1 shrink-0">
            <.link
              navigate={~p"/conversations/new"}
              class="block w-full rounded-md px-3 py-1.5 text-sm font-medium text-center
                     bg-indigo-600 text-white hover:bg-indigo-500 transition-colors"
            >
              + New Conversation
            </.link>
          </div>

          <%!-- Conversation filters --%>
          <div class="px-2 pt-0.5 pb-1 flex items-center gap-1.5 shrink-0">
            <button
              id="roots-filter-persist"
              phx-hook="RootsFilterPersist"
              type="button"
              phx-click="sidebar_toggle_roots_only"
              title={if @sidebar_roots_only, do: "Showing roots only — click to show all", else: "Show root conversations only"}
              class={[
                "shrink-0 inline-flex items-center gap-1 rounded px-2 py-1",
                "text-[11px] font-medium leading-none transition-colors border",
                if(@sidebar_roots_only,
                  do:
                    "bg-[var(--color-bg-2)] text-[var(--color-text-primary)] border-[var(--color-text-muted)]/40",
                  else:
                    "bg-transparent text-[var(--color-text-muted)] border-[var(--color-border)] hover:text-[var(--color-text-secondary)]"
                )
              ]}
            >
              <svg class="size-3 shrink-0" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
                <path d="M5 3.25a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0zm0 2.122a2.25 2.25 0 1 0-1.5 0v.878A2.25 2.25 0 0 0 5.75 8.5h1.5v2.128a2.251 2.251 0 1 0 1.5 0V8.5h1.5a2.25 2.25 0 0 0 2.25-2.25v-.878a2.25 2.25 0 1 0-1.5 0v.878a.75.75 0 0 1-.75.75h-4.5A.75.75 0 0 1 5 6.25v-.878zm3.75 7.378a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0zm3-8.75a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0z" />
              </svg>
              Roots
            </button>

            <form
              :if={length(@sidebar_unique_agents) > 1}
              phx-change="sidebar_set_agent_filter"
              class="flex-1 min-w-0"
            >
              <select
                name="agent_id"
                class="w-full rounded px-1.5 py-1 text-[11px] leading-none
                       bg-[var(--color-bg-0)] border border-[var(--color-border)]
                       text-[var(--color-text-muted)] focus:outline-none cursor-pointer"
              >
                <option value="">All agents</option>
                <option
                  :for={agent <- @sidebar_unique_agents}
                  value={agent.id}
                  selected={@sidebar_agent_filter == agent.id}
                >
                  {agent.name}
                </option>
              </select>
            </form>
          </div>

          <%!-- Recent conversations (scrollable, grouped by date) --%>
          <div class="flex-1 min-h-0 overflow-y-auto px-2 py-0.5">
            <details
              :for={{group_label, group_convs} <- @nav_conversation_groups}
              open={group_label in ["Active", "Today", "Yesterday"]}
              class="group"
            >
              <summary class="
                flex items-center gap-1 px-3 py-px
                cursor-pointer select-none
                text-[10px] uppercase tracking-wider font-medium
                text-[var(--color-text-muted)] hover:text-[var(--color-text-secondary)]
                list-none [&::-webkit-details-marker]:hidden
              ">
                <svg
                  class="size-2.5 shrink-0 -rotate-90 group-open:rotate-0 transition-transform duration-150"
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
                <span class="flex-1 flex items-center gap-1.5">
                  {group_label}
                  <span
                    :if={group_label == "Active"}
                    class="size-1.5 rounded-full bg-green-500 animate-pulse
                           shadow-[0_0_0_3px_rgba(34,197,94,0.25)]"
                  />
                </span>
                <span class="font-normal normal-case tracking-normal tabular-nums">
                  {length(group_convs)}
                </span>
              </summary>
              <.conv_nav_link
                :for={conv <- group_convs}
                conv={conv}
                current={@current_path}
                child_count={Map.get(@child_counts, conv.id, 0)}
              />
            </details>
          </div>

          <%!-- Tools section --%>
          <div class="border-t border-[var(--color-border)] px-2 py-1.5 space-y-0.5 shrink-0">
            <p class="px-3 pt-1 pb-0.5 text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium">
              Tools
            </p>
            <.nav_link href={~p"/agents"} label="Agents" current={@current_path} />
            <.nav_link href={~p"/environments"} label="Environments" current={@current_path} />
            <.nav_link href={~p"/vaults"} label="Vaults" current={@current_path} />
          </div>

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
                <.nav_link href={~p"/api-keys"} label="API Keys" current={@current_path} />
                <.nav_link href={~p"/account/billing"} label="Billing" current={@current_path} />
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
                  data-method="post"
                  class="block rounded-md px-3 py-1 text-sm text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors"
                >
                  Sign out
                </a>
              </div>
            </details>
            <button
              id="theme-toggle"
              phx-hook="ThemeToggle"
              type="button"
              aria-label="Toggle dark mode"
              class="shrink-0 mt-1 mr-1.5 rounded-md p-1.5 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-focus-ring)]"
            >
              <svg id="theme-icon-moon" class="size-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path d="M17.293 13.293A8 8 0 0 1 6.707 2.707a8.001 8.001 0 1 0 10.586 10.586z" />
              </svg>
              <svg id="theme-icon-sun" class="size-4 hidden" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path fill-rule="evenodd" d="M10 2a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0V3a1 1 0 0 1 1-1Zm4 8a4 4 0 1 1-8 0 4 4 0 0 1 8 0Zm-.464 4.95.707.707a1 1 0 0 0 1.414-1.414l-.707-.707a1 1 0 0 0-1.414 1.414Zm2.12-10.607a1 1 0 0 1 0 1.414l-.706.707a1 1 0 1 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 0ZM17 11a1 1 0 1 0 0-2h-1a1 1 0 1 0 0 2h1Zm-7 4a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0v-1a1 1 0 0 1 1-1ZM5.05 6.464A1 1 0 1 0 6.465 5.05l-.708-.707a1 1 0 0 0-1.414 1.414l.707.707Zm1.414 8.486-.707.707a1 1 0 0 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 1.414ZM4 11a1 1 0 1 0 0-2H3a1 1 0 0 0 0 2h1Z" clip-rule="evenodd" />
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
                <path fill-rule="evenodd" d="M2 4.75A.75.75 0 0 1 2.75 4h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 4.75ZM2 10a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 10Zm0 5.25a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1-.75-.75Z" clip-rule="evenodd" />
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

  defp group_conversations_by_date(convs) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)
    yesterday = Date.add(today, -1)
    week_start = Date.add(today, -7)

    {running, rest} = Enum.split_with(convs, &(&1.status == "running"))

    [
      {"Active", running},
      {"Today", Enum.filter(rest, &(conv_date(&1) == today))},
      {"Yesterday", Enum.filter(rest, &(conv_date(&1) == yesterday))},
      {"Past 7 days",
       Enum.filter(rest, fn c ->
         d = conv_date(c)
         d && Date.compare(d, week_start) != :lt && Date.compare(d, yesterday) == :lt
       end)},
      {"Older",
       Enum.filter(rest, fn c ->
         d = conv_date(c)
         d && Date.compare(d, week_start) == :lt
       end)}
    ]
    |> Enum.reject(fn {_, items} -> items == [] end)
  end

  defp conv_date(%{last_active_at: dt}) when not is_nil(dt), do: to_date(dt)
  defp conv_date(%{inserted_at: dt}) when not is_nil(dt), do: to_date(dt)
  defp conv_date(_), do: nil

  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt)

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
        "block rounded-md px-3 py-1 text-sm transition-colors",
        if(@active,
          do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-text-primary)]",
          else: "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"
        )
      ]}
    >
      {@label}
    </a>
    """
  end

  attr :conv, :map, required: true
  attr :current, :string, default: ""
  attr :child_count, :integer, default: 0

  defp conv_nav_link(assigns) do
    href = "/conversations/#{assigns.conv.id}"
    active = assigns.current == href

    first_turn =
      case assigns.conv.turns do
        %Ecto.Association.NotLoaded{} -> nil
        turns -> List.first(turns)
      end

    raw_prompt = first_turn && first_turn.prompt
    task_label = clean_conv_title(raw_prompt)
    agent = assigns.conv.agent
    agent_name = agent && agent.name
    turn_count = Map.get(assigns.conv, :turn_count, 0) || 0

    target = extract_sidebar_target(raw_prompt, agent_name)
    time_str = sidebar_relative_time(assigns.conv.last_active_at || assigns.conv.inserted_at)

    subtitle =
      [target, time_str]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    {initials, chip_class} = role_chip_style(agent_name)
    avatar_url = if agent && Map.get(agent, :avatar_media_type), do: "/agents/#{agent.id}/avatar"

    assigns =
      assign(assigns,
        href: href,
        active: active,
        task_label: task_label,
        subtitle: subtitle,
        initials: initials,
        chip_class: chip_class,
        avatar_url: avatar_url,
        turn_count: turn_count
      )

    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-2.5 rounded-md px-3 py-1.5 text-sm transition-colors",
        if(@active,
          do: "bg-[var(--color-bg-2)] text-[var(--color-text-primary)]",
          else: "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"
        )
      ]}
    >
      <%!-- Role chip: 28x28 rounded-square showing agent avatar or initials --%>
      <img
        :if={@avatar_url}
        src={@avatar_url}
        class="w-7 h-7 rounded-[6px] object-cover shrink-0"
        alt=""
        title={if @conv.agent, do: @conv.agent.name}
      />
      <span
        :if={!@avatar_url}
        class={[
          "inline-flex items-center justify-center shrink-0",
          "w-7 h-7 rounded-[6px] text-[10px] font-bold leading-none select-none",
          @chip_class
        ]}
        title={if @conv.agent, do: @conv.agent.name}
      >
        {@initials}
      </span>

      <%!-- Text block --%>
      <span class="flex-1 min-w-0">
        <%!-- Line 1: title + right-aligned counter badges --%>
        <span class="flex items-center justify-between gap-1">
          <span class="flex-1 min-w-0">
            <span
              :if={@task_label}
              class="block truncate text-[13px] text-[var(--color-text-primary)]"
            >{@task_label}</span>
            <span
              :if={!@task_label}
              class="block truncate italic text-[11px] text-[var(--color-text-muted)]"
            >(no task yet)</span>
          </span>
          <span class="shrink-0 flex items-center gap-1">
            <span
              :if={@turn_count > 0}
              class="inline-flex items-center gap-0.5 rounded px-1 py-0.5
                     text-[10px] font-medium leading-none
                     bg-[var(--color-bg-2)] text-[var(--color-text-muted)]
                     border border-[var(--color-border)]"
              title={~s(#{@turn_count} #{if @turn_count == 1, do: ~s(turn), else: ~s(turns)})}
            >
              <svg class="size-2.5" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
                <path fill-rule="evenodd" d="M1 2.75A.75.75 0 0 1 1.75 2h12.5a.75.75 0 0 1 .75.75v8.5a.75.75 0 0 1-.75.75h-6.5L5 14v-2H1.75a.75.75 0 0 1-.75-.75v-8.5Z" clip-rule="evenodd" />
              </svg>
              {@turn_count}
            </span>
            <span
              :if={@child_count > 0}
              class="inline-flex items-center gap-0.5 rounded px-1 py-0.5
                     text-[10px] font-medium leading-none
                     bg-[var(--color-bg-2)] text-[var(--color-text-muted)]
                     border border-[var(--color-border)]"
              title={~s(#{@child_count} #{if @child_count == 1, do: ~s(branch), else: ~s(branches)})}
            >
              <svg class="size-2.5" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
                <path d="M5 3.25a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0zm0 2.122a2.25 2.25 0 1 0-1.5 0v.878A2.25 2.25 0 0 0 5.75 8.5h1.5v2.128a2.251 2.251 0 1 0 1.5 0V8.5h1.5a2.25 2.25 0 0 0 2.25-2.25v-.878a2.25 2.25 0 1 0-1.5 0v.878a.75.75 0 0 1-.75.75h-4.5A.75.75 0 0 1 5 6.25v-.878zm3.75 7.378a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0zm3-8.75a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0z" />
              </svg>
              {@child_count}
            </span>
          </span>
        </span>

        <%!-- Line 2: target · timestamp --%>
        <span
          :if={@subtitle != ""}
          class="block text-[11px] text-[var(--color-text-muted)] truncate"
        >{@subtitle}</span>
      </span>
    </a>
    """
  end

  # Returns {initials, tailwind_classes} for a role chip.
  # Known roles use the curated @role_styles map.
  # Unknown roles derive initials from word-initial letters of the agent name.
  defp role_chip_style(nil) do
    {"?", "bg-[var(--color-bg-2)] text-[var(--color-text-muted)]"}
  end

  defp role_chip_style(agent_name) do
    case Map.get(@role_styles, agent_name) do
      {_initials, _classes} = style ->
        style

      nil ->
        initials =
          agent_name
          |> String.split(["_", "-", " "])
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(2)
          |> Enum.map_join("", &String.first/1)
          |> String.upcase()

        initials = if initials == "", do: "?", else: initials
        {initials, "bg-[var(--color-bg-2)] text-[var(--color-text-muted)]"}
    end
  end

  # Strip leading boilerplate from a first-turn prompt, then return the
  # first meaningful line truncated to 55 chars. Returns nil if the
  # prompt is nil or reduces to empty after stripping.
  defp clean_conv_title(nil), do: nil

  defp clean_conv_title(prompt) when is_binary(prompt) do
    cleaned =
      Enum.reduce(@strip_regexes, String.trim(prompt), fn pat, acc ->
        Regex.replace(pat, acc, "", global: false)
      end)
      |> String.trim()

    case cleaned do
      "" ->
        nil

      text ->
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> List.first()
        |> truncate(55)
    end
  end

  # Extract the most identifying target from a prompt for use as the
  # subtitle leading element. Patterns tried in order:
  #   1. GitHub PR URL  -> owner/repo#123
  #   2. GitHub repo URL -> owner/repo
  #   3. repo_url=...   -> owner/repo
  # Falls back to the agent name (which may itself be nil).
  defp extract_sidebar_target(_prompt, nil), do: nil
  defp extract_sidebar_target(nil, agent_name), do: agent_name

  defp extract_sidebar_target(prompt, agent_name) when is_binary(prompt) do
    cond do
      m = Regex.run(~r{github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)}, prompt) ->
        [_, repo, pr] = m
        "#{repo}##{pr}"

      m = Regex.run(~r{github\.com/([^/\s]+/[^/\s#?]+)(?:/|\s|$)}, prompt) ->
        Enum.at(m, 1)

      m = Regex.run(~r{repo_url=https?://[^\s]*/([^/\s]+/[^/\s]+)(?:\s|$)}, prompt) ->
        Enum.at(m, 1)

      true ->
        agent_name
    end
  end

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) do
    text = text |> String.trim() |> String.replace(~r/\s+/, " ")
    if String.length(text) > max, do: String.slice(text, 0, max) <> "\u2026", else: text
  end

  defp sidebar_relative_time(nil), do: nil
  defp sidebar_relative_time(%NaiveDateTime{} = dt),
    do: sidebar_relative_time(DateTime.from_naive!(dt, "Etc/UTC"))

  defp sidebar_relative_time(%DateTime{} = dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt))

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
