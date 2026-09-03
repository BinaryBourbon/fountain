defmodule FountainWeb.AdminLive.UserDetail do
  @moduledoc """
  Admin support view of a single account (#446): the investigative half of the
  admin story. Everything on this page is read-only — the levers (suspend,
  comp, delete, role) stay on `/admin` next to their confirmations.

  Shows account/billing state, resource counts, conversations, API-key
  metadata (never key material), the user's own audit trail, and every admin action
  taken against them. Each visit records an `admin.user.viewed` admin
  audit event: cross-tenant reads are privileged actions and get the same
  trail as cross-tenant writes.
  """
  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.{Accounts, Agents, Audit, Conversations, Environments, Quotas, Vaults}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Accounts.get_user(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "User not found — the account may have been deleted")
         |> push_navigate(to: ~p"/admin")}

      user ->
        # connected?-guard: mount runs for both the static render and the
        # socket; one visit must be one audit row.
        if connected?(socket) do
          Audit.record_admin(%{
            actor_user_id: socket.assigns.current_user.id,
            target_user_id: user.id,
            event_type: "admin.user.viewed",
            metadata: %{"email" => user.email}
          })
        end

        credits_enabled = Fountain.Credits.enabled?()

        {:ok,
         socket
         |> assign(:page_title, "Admin · #{user.email}")
         |> assign(:credits_enabled, credits_enabled)
         |> load_user(user)}
    end
  end

  # Ownership context for the _unsafe_ call below: this is an admin surface
  # behind require_admin, and `user` came from the mount fetch above.
  defp load_user(socket, user) do
    conversations = user.id |> Conversations.list_conversations() |> Enum.take(25)

    # last_activity_at is a computed column in list_users_admin/1, not a User
    # field — here the freshest conversation stands in for it.
    last_activity =
      conversations
      |> Enum.map(& &1.last_active_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    socket
    |> assign(:user, user)
    |> assign(:last_activity_at, last_activity)
    |> assign(:active_sandboxes, Map.get(Quotas.active_sandbox_counts(), user.id, 0))
    |> assign(:conversations, conversations)
    |> assign(:api_keys, Accounts.list_api_keys(user.id))
    |> assign(:agent_count, length(Agents.list_agents(user.id, [])))
    |> assign(:environment_count, length(Environments.list_environments(user.id)))
    |> assign(:vault_count, length(Vaults.list_vaults(user.id)))
    |> assign(:audit_events, Audit.list_recent_for_user(user.id, 50))
    |> assign(:admin_events, Audit._unsafe_list_admin_events_for_target(user.id, 50))
    |> assign(:credits, Fountain.Credits.summary(user))
    |> assign(:ledger, Fountain.Credits.list_entries(user.id, limit: 20))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.admin_tabs current={:users} credits_enabled={@credits_enabled} />
        <h1 class="text-2xl font-semibold font-mono mt-4">{@user.email}</h1>
        <div class="flex flex-wrap items-center gap-2 mt-2 text-xs">
          <span class={[
            "inline-flex items-center rounded px-1.5 py-0.5 font-medium border",
            if(@user.role == "admin",
              do: "bg-amber-100 text-amber-800 border-amber-200",
              else: "bg-zinc-100 text-zinc-600 border-zinc-200"
            )
          ]}>
            {@user.role}
          </span>
          <span
            :if={@credits_enabled}
            class={[
              "inline-flex items-center rounded px-1.5 py-0.5 font-medium border",
              account_badge_class(@user.comped)
            ]}
          >
            {if @user.comped,
              do: "comped",
              else: Fountain.Credits.format_cents(@user.credit_balance_cents)}
          </span>
          <span
            :if={is_nil(@user.email_verified_at)}
            class="inline-flex items-center rounded px-1.5 py-0.5 font-medium border bg-zinc-100 text-zinc-500 border-zinc-200"
          >
            unverified
          </span>
          <span
            :if={@user.suspended_at}
            class="inline-flex items-center rounded px-1.5 py-0.5 font-medium border bg-red-100 text-red-700 border-red-200"
          >
            suspended since {format_ts(@user.suspended_at)}
          </span>
          <a
            :if={@credits_enabled and @user.stripe_customer_id not in [nil, ""]}
            href={"https://dashboard.stripe.com/customers/#{@user.stripe_customer_id}"}
            target="_blank"
            rel="noopener"
            class="text-zinc-400 hover:text-zinc-700 underline"
          >
            stripe ↗
          </a>
        </div>
        <p class="text-xs text-zinc-400 mt-2 font-mono">{@user.id}</p>
      </div>

      <section class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Joined</div>
          <div class="text-sm font-medium">{format_date(@user.inserted_at)}</div>
          <div class="text-xs text-zinc-500">
            last active {if @last_activity_at, do: format_date(@last_activity_at), else: "—"}
          </div>
        </div>
        <div
          :if={not @credits_enabled}
          class="bg-white rounded shadow border border-zinc-200 px-4 py-3"
        >
          <div class="text-xs text-zinc-500">Onboarding</div>
          <div class="text-sm font-medium">
            {if @user.onboarding_completed_at, do: "completed", else: "not completed"}
          </div>
          <div class="text-xs text-zinc-500">
            {if @user.onboarding_completed_at,
              do: format_date(@user.onboarding_completed_at),
              else: "—"}
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Sandboxes</div>
          <div class="text-sm font-medium tabular-nums">
            {@active_sandboxes} / {Fountain.Quotas.sandbox_limit_for(@user)}
          </div>
          <div class="text-xs text-zinc-500">
            active / limit · {if @user.sandbox_limit_override,
              do: "override",
              else: "what the balance funds"}
          </div>
        </div>
        <div :if={@credits.active?} class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Credits</div>
          <div class={[
            "text-sm font-medium tabular-nums",
            @credits.balance_cents < 0 && "text-amber-700"
          ]}>
            {Fountain.Credits.format_cents(@credits.balance_cents)}
          </div>
          <div class="text-xs text-zinc-500">
            {Fountain.Credits.format_cents(@credits.purchased_cents)} bought · {Fountain.Credits.format_cents(
              @credits.expiring_cents
            )} expiring
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Resources</div>
          <div class="text-sm font-medium tabular-nums">
            {@agent_count}a · {@environment_count}e · {@vault_count}v
          </div>
          <div class="text-xs text-zinc-500">agents · environments · vaults</div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Conversations (latest {length(@conversations)})</h2>
        <div :if={@conversations == []} class="text-sm text-zinc-500">None.</div>
        <table
          :if={@conversations != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">Conversation</th>
              <th class="px-4 py-2">Status</th>
              <th class="px-4 py-2">Runtime</th>
              <th class="px-4 py-2">Started</th>
              <th class="px-4 py-2">Last active</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @conversations} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-2 text-xs">
                <.link
                  navigate={~p"/admin/conversations/#{c.id}"}
                  class="font-mono hover:underline"
                >
                  {String.slice(c.id, 0, 8)}
                </.link>
                <span :if={c.title} class="text-zinc-500 ml-1">{c.title}</span>
              </td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  conversation_status_color(c.status)
                ]}>
                  {c.status}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{c.runtime}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_ts(c.inserted_at)}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_ts(c.last_active_at)}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">API keys ({length(@api_keys)})</h2>
        <div :if={@api_keys == []} class="text-sm text-zinc-500">None.</div>
        <table
          :if={@api_keys != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">Name</th>
              <th class="px-4 py-2">Prefix</th>
              <th class="px-4 py-2">Scopes</th>
              <th class="px-4 py-2">Created</th>
              <th class="px-4 py-2">Last used</th>
              <th class="px-4 py-2">State</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={k <- @api_keys} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-2 text-xs">{k.name}</td>
              <td class="px-4 py-2 font-mono text-xs">{k.key_prefix}…</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{Enum.join(k.scopes, ", ")}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_date(k.inserted_at)}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">
                {if k.last_used_at, do: format_ts(k.last_used_at), else: "never"}
              </td>
              <td class="px-4 py-2 text-xs">
                <span :if={k.revoked_at} class="text-red-600">revoked</span>
                <span :if={is_nil(k.revoked_at) and k.expires_at} class="text-zinc-500">
                  expires {format_date(k.expires_at)}
                </span>
                <span :if={is_nil(k.revoked_at) and is_nil(k.expires_at)} class="text-zinc-500">
                  active
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Admin actions on this account</h2>
        <div :if={@admin_events == []} class="text-sm text-zinc-500">None recorded.</div>
        <table
          :if={@admin_events != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200"
        >
          <tbody>
            <tr :for={e <- @admin_events} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-1.5 text-xs text-zinc-500">{format_ts(e.inserted_at)}</td>
              <td class="px-4 py-1.5 font-mono text-xs">{e.event_type}</td>
              <td class="px-4 py-1.5 text-xs text-zinc-500">
                <span :if={e.metadata["from"] != nil}>
                  {e.metadata["from"]} &rarr; {e.metadata["to"]}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Recent activity (audit trail)</h2>
        <div :if={@audit_events == []} class="text-sm text-zinc-500">Nothing recorded.</div>
        <table
          :if={@audit_events != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200"
        >
          <tbody>
            <tr :for={e <- @audit_events} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-1.5 text-xs text-zinc-500 whitespace-nowrap">
                {format_ts(e.inserted_at)}
              </td>
              <td class="px-4 py-1.5 font-mono text-xs">{e.action}</td>
              <td class="px-4 py-1.5 text-xs text-zinc-500">{e.resource_type}</td>
              <td class="px-4 py-1.5 text-xs text-zinc-400">{e.request_ip}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
