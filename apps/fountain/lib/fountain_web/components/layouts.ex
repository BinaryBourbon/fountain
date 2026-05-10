defmodule FountainWeb.Layouts do
  use FountainWeb, :html

  embed_templates "layouts/*"

  alias Fountain.Conversations

  def app(assigns) do
    convs = Conversations.list_conversations_by_activity()
    assigns = assign(assigns, :nav_conversations, convs)

    ~H"""
    <main class="min-h-screen bg-zinc-50 text-zinc-900">
      <.flash_group flash={@flash} />

      <%!-- Update available banner --%>
      <div
        :if={not is_nil(assigns[:update_status]) and assigns.update_status.has_update}
        class="bg-blue-600 text-white px-4 py-2 flex items-center justify-between text-sm"
      >
        <span>
          &#11014; Version {@update_status.latest_version} is available
          <span class="text-blue-200 text-xs ml-2">(current: {@update_status.current_version})</span>
        </span>
        <div class="flex items-center gap-3">
          <button
            phx-click="check_for_updates"
            disabled={assigns[:update_status] && assigns.update_status.checking}
            class="text-blue-100 hover:text-white underline text-xs disabled:opacity-50"
          >
            <%= if assigns[:update_status] && assigns.update_status.checking, do: "Checking…", else: "Check for updates" %>
          </button>
          <button
            phx-click="upgrade"
            class="bg-white text-blue-600 hover:bg-blue-50 px-3 py-1 rounded text-xs font-medium"
          >
            Upgrade
          </button>
        </div>
      </div>

      <div class="flex">
        <aside class="hidden md:flex flex-col w-56 h-screen sticky top-0 border-r border-zinc-200 bg-white">
          <div class="p-4 border-b border-zinc-200 shrink-0">
            <a href={~p"/"} class="text-lg font-semibold tracking-tight">AoD</a>
            <div class="text-xs text-zinc-500">agent on demand</div>
          </div>

          <div class="px-2 pt-2 shrink-0">
            <.nav_link href={~p"/"} label="Conversations" current={@current_path}/>
          </div>

          <nav class="px-2 py-1 text-sm flex-1 min-h-0 overflow-y-auto">
            <div :if={@nav_conversations == []} class="px-3 py-2 text-xs text-zinc-400 italic">
              no conversations
            </div>
            <%= for conv <- @nav_conversations do %>
              <.conv_nav_link conv={conv} current={@current_path}/>
            <% end %>
          </nav>

          <div class="border-t border-zinc-200 px-2 py-2 shrink-0">
            <.nav_link href={~p"/help"} label="Help" current={@current_path}/>
          </div>

          <div class="border-t border-zinc-200 px-2 py-2 shrink-0">
            <div class="px-3 pt-1 pb-1 text-[10px] uppercase tracking-wider text-zinc-400 font-medium">
              Configure
            </div>
            <.nav_link href={~p"/agents"} label="Agents" current={@current_path}/>
            <.nav_link href={~p"/environments"} label="Environments" current={@current_path}/>
            <.nav_link href={~p"/vaults"} label="Vaults" current={@current_path}/>
            <.nav_link href={~p"/audit"} label="Audit log" current={@current_path}/>
          </div>

          <div class="border-t border-zinc-200 px-2 py-3 text-xs text-zinc-500 shrink-0">
            <a href={~p"/logout"} data-method="post" class="block px-3 py-1 hover:text-zinc-800">Sign out</a>
            <button onclick="window.toggleCheatsheet && window.toggleCheatsheet()" class="block w-full text-left px-3 py-1 hover:text-zinc-800">
              Shortcuts <kbd class="ml-1 px-1 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono">?</kbd>
            </button>
            <button
              phx-click="check_for_updates"
              disabled={not is_nil(assigns[:update_status]) and assigns.update_status.checking}
              class="block w-full text-left px-3 py-1 hover:text-zinc-800 disabled:opacity-50"
            >
              <%= cond do %>
                <% not is_nil(assigns[:update_status]) and assigns.update_status.checking -> %>Checking…
                <% not is_nil(assigns[:update_status]) and assigns.update_status.has_update -> %>Update available &#11014;
                <% true -> %>Check for updates
              <% end %>
            </button>
          </div>
        </aside>
        <section class="flex-1 p-6">
          {@inner_content}
        </section>
      </div>
    </main>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, default: ""

  defp nav_link(assigns) do
    active = String.starts_with?(assigns.current || "", assigns.href) and assigns.href != "/"
    active = active or assigns.current == assigns.href

    assigns = assign(assigns, :active, active)

    ~H"""
    <a href={@href} class={[
      "block rounded px-3 py-1.5 text-sm hover:bg-zinc-100",
      @active && "bg-zinc-100 font-medium",
      not @active && "text-zinc-600"
    ]}>{@label}</a>
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

    task_label = if first_turn, do: truncate(first_turn.prompt, 60), else: nil

    agent_name = assigns.conv.agent && assigns.conv.agent.name

    meta =
      [agent_name, assigns.conv.runtime, sidebar_relative_time(assigns.conv.updated_at)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    {dot_class, status_label} =
      case assigns.conv.status do
        "running" -> {"bg-emerald-500 animate-pulse", "running"}
        "idle" -> {"bg-zinc-400", "idle"}
        "pending" -> {"bg-amber-400", "pending"}
        other -> {"bg-zinc-300", other}
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
    <a href={@href} class={[
      "flex items-start gap-2 rounded px-3 py-2 text-sm hover:bg-zinc-100 group",
      @active && "bg-zinc-100 font-medium",
      not @active && "text-zinc-600"
    ]}>
      <span class={["size-2 rounded-full shrink-0 mt-1.5", @dot_class]} title={@status_label}/>
      <span class="flex-1 min-w-0">
        <span :if={@task_label} class="block truncate">{@task_label}</span>
        <span :if={!@task_label} class="block truncate italic text-zinc-400">(no task yet)</span>
        <span :if={@meta != ""} class="block text-[11px] text-zinc-400 truncate mt-0.5">{@meta}</span>
      </span>
    </a>
    """
  end

  defp truncate(nil, _max), do: nil
  defp truncate(text, max) do
    text = text |> String.trim() |> String.replace(~r/\s+/, " ")
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
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
