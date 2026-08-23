defmodule FountainWeb.VaultsLive.Form do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Crypto, Vaults}
  alias Fountain.Vaults.Vault

  @impl true
  def mount(params, _session, socket) do
    user_id = socket.assigns.current_user.id
    {vault, action} = load(params, user_id)

    # No DEK in assigns (#391): LiveView crash reports dump the channel
    # state — assigns included — to the logger and Sentry, and the tenant
    # DEK decrypts every secret the tenant owns. add_secret loads it per
    # write instead. Same reason the secret form below is uncontrolled:
    # the in-flight plaintext must not live in assigns either.
    {:ok,
     socket
     |> assign(:page_title, page_title(action))
     |> assign(:user_id, user_id)
     |> assign(:action, action)
     |> assign(:vault, vault)
     |> assign(:form, vault_to_form(vault))
     |> assign(:errors, %{})
     |> assign(:secrets, secrets_for(vault))
     |> assign(:secret_form_version, 0)}
  end

  defp load(%{"id" => id}, user_id), do: {Vaults.get_vault!(id, user_id), :edit}
  defp load(_, _user_id), do: {%Vault{}, :new}

  defp page_title(:new), do: "New vault"
  defp page_title(:edit), do: "Edit vault"

  defp vault_to_form(%Vault{} = v) do
    %{
      "name" => v.name || "",
      "description" => v.description || ""
    }
  end

  defp secrets_for(%Vault{id: nil}), do: []
  # Ownership: vault is loaded via the tenant-scoped get_vault!/2 in load/2.
  defp secrets_for(vault), do: Vaults._unsafe_list_secrets(vault)

  @impl true
  def handle_event("validate", %{"vault" => params}, socket) do
    {:noreply, assign(socket, :form, params)}
  end

  def handle_event("submit", %{"vault" => params}, socket) do
    save(socket, params)
  end

  def handle_event("add_secret", %{"secret" => %{"key" => k, "value" => v} = params}, socket)
      when k != "" and v != "" do
    with {:ok, dek} <- Crypto.load_tenant_key(socket.assigns.user_id),
         {:ok, _} <-
           Vaults.upsert_secret(
             socket.assigns.vault,
             %{"key" => k, "value" => v, "expires_at" => parse_expiry(params["expires_at"])},
             dek,
             FountainWeb.Audited.attribution(socket)
           ) do
      {:noreply,
       socket
       |> assign(:secrets, secrets_for(socket.assigns.vault))
       |> update(:secret_form_version, &(&1 + 1))
       |> put_flash(:info, "Secret saved")}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, secret_error(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not load encryption key: #{inspect(reason)}")}
    end
  end

  def handle_event("add_secret", _, socket), do: {:noreply, socket}

  def handle_event("delete_secret", %{"id" => id}, socket) do
    secret = Enum.find(socket.assigns.secrets, &(&1.id == id))

    if secret do
      Vaults.delete_secret(socket.assigns.vault, secret, FountainWeb.Audited.attribution(socket))

      {:noreply,
       socket
       |> assign(:secrets, secrets_for(socket.assigns.vault))
       |> put_flash(:info, "Deleted secret #{secret.key}")}
    else
      {:noreply, socket}
    end
  end

  defp save(%{assigns: %{action: :new}} = socket, attrs) do
    attrs = Map.put(attrs, "user_id", socket.assigns.user_id)

    case Vaults.create_vault(attrs, FountainWeb.Audited.attribution(socket)) do
      {:ok, vault} ->
        {:noreply,
         socket
         |> put_flash(:info, "Vault created")
         |> push_navigate(to: ~p"/vaults/#{vault.id}/edit")}

      {:error, cs} ->
        {:noreply, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp save(%{assigns: %{action: :edit, vault: vault}} = socket, attrs) do
    case Vaults.update_vault(vault, attrs, FountainWeb.Audited.attribution(socket)) do
      {:ok, _vault} ->
        {:noreply, socket |> put_flash(:info, "Vault updated") |> push_navigate(to: ~p"/vaults")}

      {:error, cs} ->
        {:noreply, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Map.new(fn {k, [first | _]} -> {to_string(k), first} end)
  end

  # The date input submits "YYYY-MM-DD" or "". The recorded instant is the end
  # of that day UTC: "expires on the 12th" means it still works on the 12th.
  defp parse_expiry(date_string) when is_binary(date_string) and date_string != "" do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp parse_expiry(_), do: nil

  defp expiry_status(%{expires_at: nil}), do: nil

  defp expiry_status(%{expires_at: expires_at}) do
    days = Date.diff(DateTime.to_date(expires_at), Date.utc_today())

    cond do
      days < 0 -> {:expired, "expired #{DateTime.to_date(expires_at)}"}
      days == 0 -> {:expiring, "expires today"}
      days <= 14 -> {:expiring, "expires in #{days}d"}
      true -> {:ok, "expires #{DateTime.to_date(expires_at)}"}
    end
  end

  defp expiry_class(:expired), do: "text-rose-600"
  defp expiry_class(:expiring), do: "text-amber-600"
  defp expiry_class(:ok), do: "text-zinc-400"

  defp updated_ago(%{updated_at: %DateTime{} = at}) do
    days = Date.diff(Date.utc_today(), DateTime.to_date(at))

    cond do
      days <= 0 -> "updated today"
      days == 1 -> "updated yesterday"
      days < 60 -> "updated #{days}d ago"
      true -> "updated #{div(days, 30)}mo ago"
    end
  end

  defp secret_error(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.flat_map(fn {k, msgs} -> Enum.map(msgs, &"#{k}: #{&1}") end)
    |> Enum.join("; ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl space-y-6">
      <h1 class="text-2xl font-semibold">{page_title(@action)}</h1>

      <form
        phx-change="validate"
        phx-submit="submit"
        class="space-y-4 bg-white rounded shadow p-6 border border-zinc-200"
      >
        <.input
          id="vault_name"
          name="vault[name]"
          label="Name"
          value={@form["name"]}
          autofocus
          required
        />
        <.error_msg field="name" errors={@errors} />

        <.input
          id="vault_description"
          name="vault[description]"
          type="textarea"
          rows="3"
          label="Description (optional)"
          value={@form["description"]}
          placeholder="Whose credentials these are, when to use them, etc."
        />

        <div class="flex gap-2">
          <.btn type="submit" phx-disable-with="Saving…">Save</.btn>
          <.link navigate={~p"/vaults"}>
            <.btn_secondary>Cancel</.btn_secondary>
          </.link>
        </div>
      </form>

      <section
        :if={@action == :edit}
        class="bg-white rounded shadow p-6 border border-zinc-200 space-y-4"
      >
        <h2 class="text-lg font-semibold">Secrets</h2>
        <p class="text-sm text-zinc-500">
          Encrypted at rest with AES-256-GCM. When this vault is selected on a new conversation,
          these values are written into the sprite environment, overriding any matching keys from
          the agent's environment. Never returned over the API.
        </p>

        <div :if={@secrets == []} class="text-sm text-zinc-500">No secrets yet.</div>

        <table :if={@secrets != []} class="w-full text-sm">
          <tbody>
            <tr :for={s <- @secrets} class="border-b border-zinc-100 last:border-0">
              <td class="py-2 font-mono">{s.key}</td>
              <td class="py-2 text-zinc-400 font-mono text-xs">•••••••</td>
              <td class="py-2 text-xs text-zinc-400">{updated_ago(s)}</td>
              <td class="py-2 text-xs">
                <%= case expiry_status(s) do %>
                  <% nil -> %>
                    <span class="text-zinc-300">no expiry</span>
                  <% {status, label} -> %>
                    <span class={expiry_class(status)}>{label}</span>
                <% end %>
              </td>
              <td class="py-2 text-right">
                <.btn_danger phx-click="delete_secret" phx-value-id={s.id} data-confirm="Delete?">
                  Delete
                </.btn_danger>
              </td>
            </tr>
          </tbody>
        </table>

        <%!-- Uncontrolled on purpose (#391): no phx-change, no value bindings,
              so the plaintext never round-trips per keystroke or sits in
              assigns. The versioned id replaces the DOM node after a
              successful save, which is what clears the fields. --%>
        <form
          id={"vault-secret-form-#{@secret_form_version}"}
          phx-submit="add_secret"
          class="flex flex-col sm:flex-row gap-2"
        >
          <input
            type="text"
            name="secret[key]"
            placeholder="KEY"
            pattern="[A-Z][A-Z0-9_]*"
            class="flex-1 rounded border border-zinc-300 px-3 py-2 text-sm font-mono"
          />
          <input
            type="password"
            name="secret[value]"
            placeholder="value"
            class="flex-[2] rounded border border-zinc-300 px-3 py-2 text-sm font-mono"
          />
          <input
            type="date"
            name="secret[expires_at]"
            title="Expiry date (optional) — you get an email before it arrives"
            class="rounded border border-zinc-300 px-3 py-2 text-sm"
          />
          <.btn type="submit">Add secret</.btn>
        </form>
      </section>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :errors, :map, required: true

  defp error_msg(assigns) do
    ~H"""
    <p :if={Map.has_key?(@errors, @field)} class="text-rose-600 text-xs">
      {Map.get(@errors, @field)}
    </p>
    """
  end
end
