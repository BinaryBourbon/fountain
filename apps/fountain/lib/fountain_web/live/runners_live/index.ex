defmodule FountainWeb.RunnersLive.Index do
  @moduledoc """
  `/account/runners` — the user's self-hosted runners (ADR 0022): every
  machine that has connected as `fountain runner`, live online status, and
  how to start one. Refreshes on a timer because "online" is registry
  state, not a column.
  """
  use FountainWeb, :live_view

  alias Fountain.Runners

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(:page_title, "Runners")
     |> assign(:user_id, user.id)
     |> assign(:enabled, Fountain.SandboxProviders.enabled?(:runner))
     |> assign(:base_url, Fountain.PublicUrl.base())
     |> load_runners()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load_runners(socket)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Runners.get_runner(id, socket.assigns.user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Runner not found")}

      runner ->
        {:ok, _} = Runners.delete_runner(runner, FountainWeb.Audited.attribution(socket))

        {:noreply,
         socket
         |> load_runners()
         |> put_flash(:info, "Runner #{runner.name} forgotten")}
    end
  end

  defp load_runners(socket) do
    assign(socket, :runners, Runners.list_runners_with_status(socket.assigns.user_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-3xl">
      <div>
        <h1 class="text-2xl font-semibold">Runners</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Machines you own that run <code class="font-mono">fountain runner</code>
          and serve sandboxes for agents whose sandbox provider is <strong>runner</strong>.
          The agent's processes run on that machine, as you, with no isolation beyond a
          per-conversation home directory — use a machine you would hand a capable colleague
          a shell on.
        </p>
      </div>

      <div
        :if={!@enabled}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-2)] p-4 text-sm text-[var(--color-text-secondary)]"
      >
        Self-hosted runners are switched off on this instance
        (<code class="font-mono">SANDBOX_RUNNERS_ENABLED=false</code>).
      </div>

      <div
        :if={@enabled}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 space-y-2"
      >
        <p class="text-sm font-medium">Start one</p>
        <pre class="bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-3 py-2 text-xs font-mono overflow-x-auto"><code>fountain auth login          # once, with a full-scope key
    FOUNTAIN_BASE_URL={@base_url} fountain runner --name mini</code></pre>
        <p class="text-xs text-[var(--color-text-muted)]">
          Then set an agent's sandbox provider to <strong>runner</strong>. New conversations are
          placed on your most recently connected online runner; with none online, starting one is
          refused rather than queued. <a href="/docs/integrations/runners" class="underline">Guide</a>
        </p>
      </div>

      <div
        :if={@runners == []}
        class="rounded border border-dashed border-[var(--color-border)] p-8 text-center text-[var(--color-text-muted)]"
      >
        No runner has connected yet.
      </div>

      <table
        :if={@runners != []}
        id="runners"
        class="w-full text-sm bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)]"
      >
        <thead class="text-left text-[var(--color-text-muted)] border-b border-[var(--color-border)]">
          <tr>
            <th class="px-4 py-2 font-medium">Name</th>
            <th class="px-4 py-2 font-medium">Status</th>
            <th class="px-4 py-2 font-medium">Machine</th>
            <th class="px-4 py-2 font-medium">Last seen</th>
            <th class="px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={%{runner: r, online: online} <- @runners}
            id={"runner-#{r.id}"}
            class="border-b border-[var(--color-border)] last:border-0 hover:bg-[var(--color-bg-2)]"
          >
            <td class="px-4 py-2 font-medium">{r.name}</td>
            <td class="px-4 py-2">
              <span
                :if={online}
                class="inline-flex items-center gap-1.5 text-xs text-[var(--color-success-text)]"
              >
                <span class="h-2 w-2 rounded-full bg-[var(--color-success)]"></span> online
              </span>
              <span
                :if={!online}
                class="inline-flex items-center gap-1.5 text-xs text-[var(--color-text-muted)]"
              >
                <span class="h-2 w-2 rounded-full bg-[var(--color-border)]"></span> offline
              </span>
            </td>
            <td class="px-4 py-2 text-xs text-[var(--color-text-muted)]">
              <div>{r.hostname || "—"}</div>
              <div class="font-mono">
                {Enum.reject([r.os, r.arch, r.version], &is_nil/1) |> Enum.join(" · ")}
              </div>
            </td>
            <td class="px-4 py-2 text-[var(--color-text-muted)] text-xs">
              {format_time(r.last_seen_at)}
            </td>
            <td class="px-4 py-2 text-right">
              <.button
                variant="ghost"
                phx-click="delete"
                phx-value-id={r.id}
                data-confirm="Forget this runner? A daemon still running will reconnect and re-register."
                class="text-[var(--color-error)] hover:text-[var(--color-error-text)]"
              >
                Forget
              </.button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_time(nil), do: "—"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
