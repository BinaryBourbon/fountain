defmodule FountainWeb.OAuthClientsLive.Index do
  @moduledoc """
  Account → OAuth apps (#1125): the clients this account registered so that an
  app it is building can offer "Sign in with Fountain".

  Every client here is in development mode, which is what makes the redirect
  URI field free-form: it signs in its owner and renders an error page for
  everyone else, so the only account a badly-chosen redirect can send anywhere
  is the owner's own.
  """
  use FountainWeb, :live_view

  alias Fountain.OAuth
  alias Fountain.OAuth.Client
  alias FountainWeb.Audited

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "OAuth apps")
     |> assign(:user_id, user.id)
     |> assign(:clients, OAuth.list_clients(user.id))
     |> assign(:editing, nil)
     |> assign(:form_errors, [])
     |> assign(:form, blank_form())}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(:editing, :new) |> assign(:form, blank_form()) |> clear_errors()}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case OAuth.get_client_record(id, socket.assigns.user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "No such app")}

      client ->
        {:noreply,
         socket
         |> assign(:editing, client)
         |> assign(:form, %{
           "name" => client.name,
           "redirect_uris" => Enum.join(client.redirect_uris, "\n")
         })
         |> clear_errors()}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> clear_errors()}
  end

  def handle_event("save", %{"name" => name, "redirect_uris" => uris}, socket) do
    attrs = %{"name" => name, "redirect_uris" => split_uris(uris)}

    result =
      case socket.assigns.editing do
        :new ->
          OAuth.create_client(socket.assigns.user_id, attrs, Audited.attribution(socket))

        %Client{} = client ->
          OAuth.update_client(client, attrs, Audited.attribution(socket))

        # A submit queued behind the cancel that closed the form, or a
        # crafted event. There is nothing to save and nothing to report.
        nil ->
          :no_form
      end

    case result do
      :no_form ->
        {:noreply, socket}

      {:ok, _client} ->
        {:noreply,
         socket
         |> assign(:clients, OAuth.list_clients(socket.assigns.user_id))
         |> assign(:editing, nil)
         |> clear_errors()
         |> put_flash(:info, "Saved")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, %{"name" => name, "redirect_uris" => uris})
         |> assign(:form_errors, error_messages(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case OAuth.get_client_record(id, socket.assigns.user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "No such app")}

      client ->
        case OAuth.delete_client(client, Audited.attribution(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:clients, OAuth.list_clients(socket.assigns.user_id))
             |> put_flash(
               :info,
               "App deleted. Keys it already issued stay valid until revoked."
             )}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, Enum.join(error_messages(changeset), ", "))}
        end
    end
  end

  defp blank_form, do: %{"name" => "", "redirect_uris" => ""}

  defp clear_errors(socket), do: assign(socket, :form_errors, [])

  # One URI per line is what people paste; commas are a common near-miss.
  defp split_uris(text) do
    text
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp error_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-2xl">
      <div>
        <h1 class="text-2xl font-semibold">OAuth apps</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Register an app you are building so it can offer "Sign in with {Fountain.Brand.name()}"
          against this server. Registering also lets the app call the API from its own origin.
        </p>
        <p class="text-sm text-[var(--color-text-secondary)] mt-2">
          Every app here is <span class="font-medium">in development</span>: it signs you in and
          refuses every other account. Use your sandbox's public HTTPS URL or an HTTP
          <code class="font-mono text-xs">localhost</code>
          URL. A loopback URI matches on any port.
        </p>
      </div>

      <div :if={@editing == nil}>
        <.button phx-click="new">Register an app</.button>
      </div>

      <form :if={@editing != nil} phx-submit="save" class="space-y-4">
        <div
          :if={@form_errors != []}
          class="rounded border border-[var(--color-error)] bg-[var(--color-bg-2)] px-3 py-2 text-sm text-[var(--color-error-text)]"
        >
          <p :for={msg <- @form_errors}>{msg}</p>
        </div>

        <.form_field
          id="name"
          label="Name"
          name="name"
          type="text"
          value={@form["name"]}
          placeholder="e.g. Notes"
          errors={[]}
          required
        />

        <div>
          <label for="redirect_uris" class="block text-sm font-medium mb-1">Redirect URIs</label>
          <textarea
            id="redirect_uris"
            name="redirect_uris"
            rows="3"
            class="w-full rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] px-3 py-2 text-sm font-mono"
            placeholder="https://abc123.sprites.app/callback&#10;http://localhost:5173/callback"
          >{@form["redirect_uris"]}</textarea>
          <p class="text-xs text-[var(--color-text-muted)] mt-1">
            One per line. https, unless the host is localhost or 127.0.0.1.
          </p>
        </div>

        <div class="flex gap-2">
          <.button type="submit">Save</.button>
          <.button type="button" variant="secondary" phx-click="cancel">Cancel</.button>
        </div>
      </form>

      <div
        :if={@clients == []}
        class="rounded border border-dashed border-[var(--color-border)] p-8 text-center text-[var(--color-text-muted)]"
      >
        No OAuth apps yet.
      </div>

      <div
        :for={c <- @clients}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 space-y-2"
      >
        <div class="flex items-start justify-between gap-2">
          <div>
            <div class="font-medium">
              {c.name}
              <span
                :if={not c.published}
                class="ml-2 align-middle rounded bg-amber-50 text-amber-700 px-1.5 py-0.5 text-xs"
              >
                In development
              </span>
            </div>
            <code class="text-xs font-mono text-[var(--color-text-muted)]">{c.client_id}</code>
          </div>
          <div class="flex gap-1 shrink-0">
            <.button :if={not c.published} variant="ghost" phx-click="edit" phx-value-id={c.id}>
              Edit
            </.button>
            <.button
              :if={not c.published}
              variant="ghost"
              phx-click="delete"
              phx-value-id={c.id}
              data-confirm="Delete this app? New sign-ins through it will stop. Keys it already issued stay valid until you revoke them under API keys."
              class="text-[var(--color-error)] hover:text-[var(--color-error-text)]"
            >
              Delete
            </.button>
          </div>
        </div>
        <ul class="text-xs font-mono text-[var(--color-text-muted)] space-y-0.5">
          <li :for={uri <- c.redirect_uris}>{uri}</li>
        </ul>
        <p class="text-xs text-[var(--color-text-muted)]">
          Calls /api from {Enum.join(Client.origins_of(c.redirect_uris), ", ")}
        </p>
      </div>
    </div>
    """
  end
end
