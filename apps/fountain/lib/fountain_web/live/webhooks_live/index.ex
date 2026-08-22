defmodule FountainWeb.WebhooksLive.Index do
  @moduledoc """
  `/account/webhooks` — the endpoints Fountain POSTs lifecycle events to
  (#700): create one, rotate its secret, send a test event, read every
  attempt, and send one again by hand.

  The recent-deliveries panel is the point of the page. "Your webhook is
  broken" is otherwise a support thread; here it is a status code, a duration
  and the first few KB of what the receiver said.
  """
  use FountainWeb, :live_view

  alias Fountain.Webhooks
  alias Fountain.Webhooks.Events

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Webhooks")
     |> assign(:user_id, socket.assigns.current_user.id)
     |> assign(:new_secret, nil)
     |> assign(:selected, nil)
     |> assign(:deliveries, [])
     |> assign(:form_error, nil)
     |> assign(:catalogue, Events.catalogue())
     |> assign(:defaults, Events.defaults())
     |> load_endpoints()}
  end

  @impl true
  def handle_event("create", params, socket) do
    attrs = %{
      "url" => params["url"],
      "description" => blank_to_nil(params["description"]),
      "event_types" => checked_events(params)
    }

    case Webhooks.create_endpoint(socket.assigns.user_id, attrs, attribution(socket)) do
      {:ok, {endpoint, secret}} ->
        {:noreply,
         socket
         |> load_endpoints()
         |> assign(:form_error, nil)
         |> assign(:new_secret, %{endpoint: endpoint, secret: secret})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form_error, first_error(changeset))}
    end
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, :new_secret, nil)}

  def handle_event("rotate", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      case Webhooks.rotate_secret(endpoint, attribution(socket)) do
        {:ok, {endpoint, secret}} ->
          socket
          |> load_endpoints()
          |> assign(:new_secret, %{endpoint: endpoint, secret: secret})

        {:error, _} ->
          put_flash(socket, :error, "Could not rotate the secret")
      end
    end)
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn
      %{status: "active"} = endpoint ->
        {:ok, _} =
          Webhooks.disable_endpoint(endpoint, "switched off by its owner", attribution(socket))

        socket |> load_endpoints() |> put_flash(:info, "Deliveries paused")

      endpoint ->
        {:ok, _} = Webhooks.enable_endpoint(endpoint, attribution(socket))
        socket |> load_endpoints() |> put_flash(:info, "Deliveries resumed")
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      {:ok, _} = Webhooks.delete_endpoint(endpoint, attribution(socket))

      socket
      |> load_endpoints()
      |> assign(:selected, nil)
      |> assign(:deliveries, [])
      |> put_flash(:info, "Endpoint deleted")
    end)
  end

  def handle_event("test", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      {:ok, _job} = Webhooks.deliver_test_event(endpoint)
      put_flash(socket, :info, "Test event queued — it shows up below once it has been sent")
    end)
  end

  def handle_event("select", %{"id" => id}, socket) do
    with_endpoint(socket, id, fn endpoint ->
      socket
      |> assign(:selected, endpoint.id)
      |> assign(:deliveries, Webhooks.list_deliveries(endpoint, 25))
    end)
  end

  def handle_event("redeliver", %{"id" => id}, socket) do
    case Webhooks.get_delivery(id, socket.assigns.user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Delivery not found")}

      delivery ->
        {:ok, _job} = Webhooks.redeliver(delivery)
        {:noreply, put_flash(socket, :info, "Queued again")}
    end
  end

  ## ── helpers ───────────────────────────────────────────────────────────────

  defp with_endpoint(socket, id, fun) do
    case Webhooks.get_endpoint(id, socket.assigns.user_id) do
      nil -> {:noreply, put_flash(socket, :error, "Endpoint not found")}
      endpoint -> {:noreply, fun.(endpoint)}
    end
  end

  defp load_endpoints(socket),
    do: assign(socket, :endpoints, Webhooks.list_endpoints(socket.assigns.user_id))

  defp attribution(socket), do: FountainWeb.Audited.attribution(socket)

  # Unchecked boxes are absent from the params, so an empty selection falls
  # back to the defaults rather than to "subscribed to nothing".
  defp checked_events(params) do
    params
    |> Map.get("events", %{})
    |> Enum.filter(fn {_type, on} -> on in ["true", "on"] end)
    |> Enum.map(&elem(&1, 0))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp first_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}),
    do: "#{field} #{message}"

  defp first_error(_), do: "Could not save the endpoint"

  defp format_time(nil), do: "—"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp outcome_class(%{status_code: code}) when is_integer(code) and code in 200..299,
    do: "text-[var(--color-success-text)]"

  defp outcome_class(_), do: "text-[var(--color-error-text)]"

  defp outcome(%{status_code: code}) when is_integer(code), do: to_string(code)
  defp outcome(_), do: "failed"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-4xl">
      <div>
        <h1 class="text-2xl font-semibold">Webhooks</h1>
        <p class="text-sm text-[var(--color-text-secondary)] mt-1">
          Fountain POSTs lifecycle transitions to a URL of yours, signed with an HMAC secret,
          and keeps trying for about a day if your receiver is down. Conversation output does
          not come this way. For a transcript, read
          <code class="font-mono">GET /api/conversations/:id/events</code>
          with your own API key.
          <a href="/docs/reference/webhooks" class="underline">How to verify a signature</a>
        </p>
      </div>

      <.modal id="new-secret-modal" show={@new_secret != nil}>
        <:title>Signing secret</:title>
        <p class="text-sm text-[var(--color-text-secondary)] mb-4">
          Copy this now. It is not shown again, only replaced.
        </p>
        <div class="flex items-center gap-2">
          <code
            id="new-webhook-secret"
            class="flex-1 bg-[var(--color-bg-2)] rounded border border-[var(--color-border)] px-3 py-2 text-sm font-mono break-all"
          >
            {@new_secret && @new_secret.secret}
          </code>
          <.button
            phx-hook="CopyToClipboard"
            id="copy-webhook-secret"
            data-target="new-webhook-secret"
            variant="secondary"
          >
            Copy
          </.button>
        </div>
        <:footer>
          <.button phx-click="dismiss_secret" variant="secondary">
            I've copied it, dismiss
          </.button>
        </:footer>
      </.modal>

      <form
        phx-submit="create"
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] p-4 space-y-4"
      >
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <.form_field
            id="url"
            label="Endpoint URL"
            name="url"
            type="text"
            placeholder="https://example.com/hooks/fountain"
            errors={[]}
            required
          />
          <.form_field
            id="description"
            label="What is it for"
            name="description"
            type="text"
            placeholder="optional"
            errors={[]}
          />
        </div>

        <fieldset class="space-y-2">
          <legend class="text-sm font-medium">Events</legend>
          <p class="text-xs text-[var(--color-text-muted)]">
            With none ticked this endpoint gets {Enum.join(@defaults, ", ")}.
          </p>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-x-4 gap-y-1">
            <div
              :for={{stage, statuses} <- @catalogue}
              class="text-xs text-[var(--color-text-secondary)]"
            >
              <span class="font-mono font-medium">{stage}</span>
              <div class="space-x-2">
                <label :for={status <- statuses} class="inline-flex items-center gap-1">
                  <input
                    type="checkbox"
                    name={"events[conversation.#{stage}.#{status}]"}
                    value="true"
                    checked={Events.type(stage, status) in @defaults}
                    class="rounded border-[var(--color-border)]"
                  />
                  <span class="font-mono">{status}</span>
                </label>
              </div>
            </div>
          </div>
        </fieldset>

        <p :if={@form_error} class="text-sm text-[var(--color-error-text)]">{@form_error}</p>

        <.button type="submit">Add endpoint</.button>
      </form>

      <div
        :if={@endpoints == []}
        class="rounded border border-dashed border-[var(--color-border)] p-8 text-center text-[var(--color-text-muted)]"
      >
        No webhook endpoints yet.
      </div>

      <div
        :for={endpoint <- @endpoints}
        id={"endpoint-#{endpoint.id}"}
        class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)]"
      >
        <div class="p-4 space-y-2">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <p class="font-mono text-sm break-all">{endpoint.url}</p>
              <p :if={endpoint.description} class="text-xs text-[var(--color-text-muted)]">
                {endpoint.description}
              </p>
              <p class="text-xs text-[var(--color-text-muted)] mt-1">
                {Enum.join(endpoint.event_types, ", ")}
              </p>
            </div>
            <span class={[
              "shrink-0 text-xs rounded px-2 py-0.5",
              endpoint.status == "active" && "bg-[var(--color-bg-2)]",
              endpoint.status != "active" && "text-[var(--color-error-text)]"
            ]}>
              {endpoint.status}
            </span>
          </div>

          <p
            :if={endpoint.disabled_reason}
            class="text-xs text-[var(--color-error-text)]"
          >
            {endpoint.disabled_reason}
          </p>

          <div class="flex flex-wrap gap-2 pt-1">
            <.button variant="secondary" phx-click="test" phx-value-id={endpoint.id}>
              Send test event
            </.button>
            <.button variant="ghost" phx-click="select" phx-value-id={endpoint.id}>
              Recent deliveries
            </.button>
            <.button variant="ghost" phx-click="toggle" phx-value-id={endpoint.id}>
              {if endpoint.status == "active", do: "Pause", else: "Resume"}
            </.button>
            <.button
              variant="ghost"
              phx-click="rotate"
              phx-value-id={endpoint.id}
              data-confirm="Rotate the secret? The old one stops verifying immediately."
            >
              Rotate secret
            </.button>
            <.button
              variant="ghost"
              phx-click="delete"
              phx-value-id={endpoint.id}
              data-confirm="Delete this endpoint? Its delivery log goes with it."
              class="text-[var(--color-error)] hover:text-[var(--color-error-text)]"
            >
              Delete
            </.button>
          </div>
        </div>

        <div
          :if={@selected == endpoint.id}
          class="border-t border-[var(--color-border)] p-4"
        >
          <p
            :if={@deliveries == []}
            class="text-sm text-[var(--color-text-muted)]"
          >
            Nothing delivered yet.
          </p>
          <table :if={@deliveries != []} class="w-full text-xs">
            <thead class="text-left text-[var(--color-text-muted)]">
              <tr>
                <th class="py-1 font-medium">When</th>
                <th class="py-1 font-medium">Event</th>
                <th class="py-1 font-medium">Try</th>
                <th class="py-1 font-medium">Result</th>
                <th class="py-1 font-medium">Took</th>
                <th class="py-1 font-medium">Response</th>
                <th class="py-1"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={d <- @deliveries}
                id={"delivery-#{d.id}"}
                class="border-t border-[var(--color-border)]"
              >
                <td class="py-1 whitespace-nowrap text-[var(--color-text-muted)]">
                  {format_time(d.inserted_at)}
                </td>
                <td class="py-1 font-mono">{d.event_type}</td>
                <td class="py-1">{d.attempt}</td>
                <td class={["py-1 font-medium", outcome_class(d)]}>{outcome(d)}</td>
                <td class="py-1 text-[var(--color-text-muted)]">
                  {if d.duration_ms, do: "#{d.duration_ms}ms", else: "—"}
                </td>
                <td class="py-1 font-mono text-[var(--color-text-muted)] max-w-xs truncate">
                  {d.error || d.response_body}
                </td>
                <td class="py-1 text-right">
                  <.button variant="ghost" phx-click="redeliver" phx-value-id={d.id}>
                    Send again
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
