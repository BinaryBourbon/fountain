defmodule FountainWeb.ConnectionsLive.Index do
  @moduledoc """
  `/account/connections` — the provider accounts this tenant has signed in
  to, whose credentials Fountain holds (#1178). List, connect, reconnect,
  revoke. The OAuth round trip itself is `FountainWeb.ConnectionsController`;
  this page only links to it and shows what came back.

  Only for accounts the egress broker is on for: the nav link is hidden
  otherwise, and a direct visit is sent to `/account`.
  """

  use FountainWeb, :live_view

  alias Fountain.{Broker, Connections}
  alias Fountain.Connections.Google
  alias FountainWeb.Audited

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if Broker.enabled_for?(user.id) do
      {:ok,
       socket
       |> assign(:page_title, "Connections")
       |> assign(:user_id, user.id)
       |> assign(:google_configured, Google.configured?())
       |> assign(:google_scopes, Google.scopes())
       |> assign(:google_env_key, Google.env_key())
       |> reload()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Connections are not enabled for this account.")
       |> push_navigate(to: ~p"/account")}
    end
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case Connections.get_connection(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That connection is gone.")}

      connection ->
        case Connections.revoke(connection, Audited.attribution(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Revoked #{connection.account_email}. Agents that name it will be told."
             )
             |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not revoke: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user_id = socket.assigns.user_id

    case Connections.get_connection(id, user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That connection is gone.")}

      connection ->
        case Connections.delete(connection, Audited.attribution(socket)) do
          {:ok, _} ->
            {:noreply,
             socket |> put_flash(:info, "Removed #{connection.account_email}.") |> reload()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not remove: #{inspect(reason)}")}
        end
    end
  end

  defp reload(socket) do
    assign(socket, :connections, Connections.list_connections(socket.assigns.user_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-3xl">
      <div>
        <h1 class="text-2xl font-semibold">Connections</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Sign in to a provider once. Fountain keeps the refresh token, encrypted with your
          tenant key, and hands agents the capability rather than the credential: a
          Fountain-served MCP server that uses the connection on their behalf, or an access
          token brokered to the provider's hosts. No Google token ever enters a sandbox.
        </p>
      </div>

      <div class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-5 space-y-3">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 class="text-base font-medium">Google (Gmail)</h2>
            <p class="text-xs text-[var(--color-text-secondary)] mt-1">
              Scopes: <code class="font-mono">{Enum.join(@google_scopes, " ")}</code>
            </p>
            <p class="text-xs text-[var(--color-text-secondary)] mt-0.5">
              Brokered as <code class="font-mono">{@google_env_key}</code>
            </p>
          </div>
          <a
            :if={@google_configured}
            href={~p"/connections/google/start"}
            data-role="connect-google"
            class="rounded-md bg-zinc-900 px-3 py-2 text-sm text-white hover:bg-zinc-700"
          >
            Connect a Google account
          </a>
          <span :if={!@google_configured} class="text-xs text-[var(--color-text-secondary)]">
            Not configured on this deployment (<code class="font-mono">GOOGLE_OAUTH_CLIENT_ID</code>).
          </span>
        </div>
      </div>

      <div :if={@connections == []} class="text-sm text-[var(--color-text-secondary)]">
        No connections yet.
      </div>

      <div
        :for={c <- @connections}
        id={"connection-#{c.id}"}
        class="rounded-lg border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 flex items-start justify-between gap-4"
      >
        <div class="space-y-1">
          <div class="flex items-center gap-2">
            <span class="font-medium">{c.account_email}</span>
            <span
              class={[
                "rounded-full px-2 py-0.5 text-xs",
                c.status == "active" && "bg-green-100 text-green-800",
                c.status != "active" && "bg-red-100 text-red-800"
              ]}
              data-role="status"
            >
              {c.status}
            </span>
          </div>
          <p class="text-xs text-[var(--color-text-secondary)]">
            {c.provider} · id <code class="font-mono">{c.id}</code>
          </p>
          <p class="text-xs text-[var(--color-text-secondary)]">
            In an agent's MCP servers:
            <code class="font-mono">{~s({"gmail": {"connection": "#{c.id}"}})}</code>
          </p>
          <p :if={c.status == "revoked"} class="text-xs text-red-700">
            Revoked {c.revoked_at}. Connect the account again to replace it.
          </p>
        </div>
        <div class="flex gap-2 shrink-0">
          <button
            :if={c.status == "active"}
            phx-click="revoke"
            phx-value-id={c.id}
            data-confirm="Revoke this connection? Agents that use it will fail with 'connection revoked' on their next call."
            class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]"
          >
            Revoke
          </button>
          <button
            phx-click="delete"
            phx-value-id={c.id}
            data-confirm="Remove this connection entirely?"
            class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm text-red-700 hover:bg-[var(--color-bg-2)]"
          >
            Remove
          </button>
        </div>
      </div>
    </div>
    """
  end
end
