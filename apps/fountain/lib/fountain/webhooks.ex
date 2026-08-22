defmodule Fountain.Webhooks do
  @moduledoc """
  Tenant-scoped webhook endpoints and their delivery log (#700).

  Fountain spawns agents that run for minutes to hours and then go quiet.
  Holding an SSE connection open for that is a daemon every integrator has to
  write and operate; a GitHub Action, a Lambda or a cron-driven script cannot
  do it at all. This context is the callback half: a URL the tenant owns, an
  event filter, an HMAC secret, and an Oban queue that keeps trying.

  ## What crosses the wire

  Lifecycle transitions only. Dispatch hangs off
  `Fountain.Conversations.publish_stage/4`, which is the single chokepoint
  every operationally meaningful outcome flows through, so a new outcome
  cannot be added without subscribers seeing it. `kind: "output"` rows do not
  get webhooks — see `Fountain.Webhooks.Events`.

  The payload carries **no values**: ids, a stage, a status and a duration.
  Same rule the audit trail runs on (`decisions/0013`) and for the same
  reason. A webhook payload is tenant data leaving the building over a URL
  the tenant typed into a form, and `webhook_deliveries` would otherwise
  become a second, less-guarded copy of every conversation. A receiver that
  wants the transcript calls `GET /api/conversations/:id/events` with its own
  API key.

  ## Guarantees

  **At-least-once, no ordering.** Retries and parallel delivery both mean the
  same event can arrive twice and out of order. `id` is the `log_events` row
  id — stable, monotonic, and already the SSE event id — so a consumer can
  dedupe against what it saw on the stream.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.{Audit, Crypto, Repo}
  alias Fountain.Conversations.{Conversation, LogEvent}
  alias Fountain.Webhooks.{Delivery, Endpoint, Events}

  # Consecutive *events* that exhausted their retries, not attempts. With
  # `max_attempts: 8` on the worker that is roughly five days of a dead URL
  # before it is switched off, which is long enough to cover a holiday and
  # short enough that the queue is not carrying it forever.
  @failure_threshold 5

  @doc "Whether webhook dispatch is switched on for this instance."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fountain, :webhooks_enabled, true)

  @doc "How many failed events in a row disable an endpoint."
  def failure_threshold, do: @failure_threshold

  @doc "The audit actor for the unattended delivery path."
  def actor, do: "system:webhook_delivery"

  ## ── endpoints ─────────────────────────────────────────────────────────────

  @doc "List a user's endpoints, newest first."
  def list_endpoints(user_id) when is_binary(user_id) do
    Repo.all(
      from e in Endpoint,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  @doc "Get an endpoint scoped to user. Returns nil on wrong owner or missing id."
  def get_endpoint(id, user_id) when is_binary(user_id) do
    Repo.get_by(Endpoint, id: id, user_id: user_id)
  end

  @doc "WARNING: lookup by id without owner check. Delivery/admin use only."
  def _unsafe_get_endpoint(id), do: Repo.get(Endpoint, id)

  @doc """
  Create an endpoint. Returns `{:ok, {endpoint, secret}}` — the plaintext
  signing secret is shown exactly once and is not recoverable afterwards.

  `attrs` is a string-keyed map (`"url"`, `"description"`, `"event_types"`).
  An absent or empty `event_types` subscribes to
  `Fountain.Webhooks.Events.defaults/0`.

  `opts` carries the audit attribution, as everywhere else in this codebase.
  """
  @spec create_endpoint(String.t(), map(), keyword()) ::
          {:ok, {Endpoint.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_endpoint(user_id, attrs, opts \\ []) when is_binary(user_id) do
    secret = Endpoint.generate_secret()

    attrs =
      attrs
      |> stringify()
      |> Map.put("user_id", user_id)
      |> Map.put("secret", secret)
      |> Map.update("event_types", Events.defaults(), fn
        nil -> Events.defaults()
        [] -> Events.defaults()
        types -> types
      end)

    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, endpoint} <- %Endpoint{} |> Endpoint.changeset(attrs, dek) |> Repo.insert() do
      audit(endpoint, "webhook_endpoint.created", opts)
      {:ok, {endpoint, secret}}
    end
  end

  @doc """
  Update the URL, description or event filter. See `create_endpoint/3` for
  `opts`. The secret is not settable here — use `rotate_secret/2`.
  """
  @spec update_endpoint(Endpoint.t(), map(), keyword()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def update_endpoint(%Endpoint{} = endpoint, attrs, opts \\ []) do
    attrs = attrs |> stringify() |> Map.drop(["secret", "user_id"])

    with {:ok, dek} <- Crypto.load_tenant_key(endpoint.user_id) do
      changeset = Endpoint.changeset(endpoint, attrs, dek)

      case Repo.update(changeset) do
        {:ok, updated} ->
          audit(
            updated,
            "webhook_endpoint.updated",
            merge_metadata(opts, Audit.changed_fields(changeset))
          )

          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc """
  Mint a fresh signing secret. Returns `{:ok, {endpoint, secret}}`; the old
  secret stops verifying immediately, so a receiver has to be updated in the
  same breath.
  """
  @spec rotate_secret(Endpoint.t(), keyword()) ::
          {:ok, {Endpoint.t(), String.t()}} | {:error, Ecto.Changeset.t() | term()}
  def rotate_secret(%Endpoint{} = endpoint, opts \\ []) do
    secret = Endpoint.generate_secret()

    with {:ok, dek} <- Crypto.load_tenant_key(endpoint.user_id),
         {:ok, updated} <-
           endpoint |> Endpoint.changeset(%{"secret" => secret}, dek) |> Repo.update() do
      audit(updated, "webhook_endpoint.secret_rotated", opts)
      {:ok, {updated, secret}}
    end
  end

  @doc "Delete an endpoint. Its delivery log goes with it by cascade."
  def delete_endpoint(%Endpoint{} = endpoint, opts \\ []) do
    case Repo.delete(endpoint) do
      {:ok, deleted} ->
        audit(deleted, "webhook_endpoint.deleted", opts)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Switch an endpoint off. Called by the delivery worker after
  `failure_threshold/0` consecutive failed events, and by the owner from the
  console.
  """
  def disable_endpoint(%Endpoint{} = endpoint, reason, opts \\ []) do
    changes = [
      status: "disabled",
      disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      disabled_reason: reason,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    ]

    {1, _} = Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint.id), set: changes)
    updated = struct(endpoint, changes)

    audit(updated, "webhook_endpoint.disabled", merge_metadata(opts, %{"reason" => reason}))

    {:ok, updated}
  end

  @doc "Switch an endpoint back on, clearing the failure counter."
  def enable_endpoint(%Endpoint{} = endpoint, opts \\ []) do
    changes = [
      status: "active",
      disabled_at: nil,
      disabled_reason: nil,
      consecutive_failures: 0,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    ]

    {1, _} = Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint.id), set: changes)
    updated = struct(endpoint, changes)

    audit(updated, "webhook_endpoint.enabled", opts)

    {:ok, updated}
  end

  @doc """
  The endpoint's plaintext signing secret.

  A system read: the delivery worker has to sign with it. Ownership rides on
  the row's own `user_id`, which is also the tenant whose DEK unwraps it, so
  there is no way to read one tenant's secret with another's key.
  """
  @spec secret(Endpoint.t()) :: {:ok, String.t()} | :error
  def secret(%Endpoint{} = endpoint) do
    case Crypto.load_tenant_key(endpoint.user_id) do
      {:ok, dek} -> Endpoint.decrypt_secret(endpoint, dek)
      _ -> :error
    end
  end

  ## ── deliveries ────────────────────────────────────────────────────────────

  @doc "Recent attempts against one endpoint, newest first."
  def list_deliveries(%Endpoint{id: id}, limit \\ 50) do
    Repo.all(
      from d in Delivery,
        where: d.webhook_endpoint_id == ^id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^limit
    )
  end

  @doc "Get a delivery scoped to user, through its endpoint."
  def get_delivery(id, user_id) when is_binary(user_id) do
    Repo.one(
      from d in Delivery,
        join: e in Endpoint,
        on: d.webhook_endpoint_id == e.id,
        where: d.id == ^id and e.user_id == ^user_id
    )
  end

  @doc "Record one attempt. Never raises — a lost delivery row must not lose the delivery."
  def record_delivery(attrs) do
    %Delivery{}
    |> Delivery.changeset(attrs)
    |> Repo.insert()
  rescue
    error ->
      Logger.warning("webhooks: could not record delivery: #{inspect(error)}")
      {:error, error}
  end

  ## ── dispatch ──────────────────────────────────────────────────────────────

  @doc """
  Enqueue one job per matching active endpoint for a stage transition.

  Called from `Fountain.Conversations.publish_stage/4`, which is on the
  conversation's own hot path, so this is best-effort by construction: it
  rescues everything and returns `:ok`. A webhook that is not sent is a
  degraded integration; a stage transition that raises is a stuck agent.

  One job per (endpoint, event), so a slow endpoint cannot stall a fast one.
  """
  @spec dispatch_stage(LogEvent.t()) :: :ok
  def dispatch_stage(%LogEvent{kind: "stage"} = event) do
    if enabled?() do
      do_dispatch(event)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning("webhooks: dispatch failed: #{inspect(error)}")
      :ok
  end

  def dispatch_stage(_event), do: :ok

  defp do_dispatch(event) do
    type = Events.type(event.stage, event.state)

    with %{} = conv <- conversation_facts(event.conversation_id),
         [_ | _] = endpoints <- active_endpoints_for(conv.user_id, type) do
      payload = payload(event, conv, type)

      Enum.each(endpoints, fn endpoint ->
        Fountain.Workers.WebhookDelivery.enqueue(endpoint.id, payload)
      end)
    else
      _ -> :ok
    end

    :ok
  end

  defp conversation_facts(nil), do: nil

  defp conversation_facts(conversation_id) do
    Repo.one(
      from c in Conversation,
        where: c.id == ^conversation_id,
        select: %{
          id: c.id,
          user_id: c.user_id,
          agent_id: c.agent_id,
          parent_conversation_id: c.parent_conversation_id,
          status: c.status
        }
    )
  end

  # Filtering in Elixir rather than in SQL: the filter vocabulary has
  # wildcards, `event_types` is a small array, and a tenant has a handful of
  # endpoints. An array containment query would have to be written twice —
  # once for the exact form and once for each wildcard shape.
  defp active_endpoints_for(user_id, type) do
    from(e in Endpoint, where: e.user_id == ^user_id and e.status == "active")
    |> Repo.all()
    |> Enum.filter(&Events.matches?(&1.event_types, type))
  end

  @doc """
  The event envelope. Ids, a stage, a status, a duration. Nothing else, ever.

  `status` is the conversation's status as read at dispatch time, which can
  be stale by a hair against the transition that triggered it. Documented as
  advisory; `stage` and `state` are the authoritative pair.
  """
  @spec payload(LogEvent.t(), map(), String.t()) :: map()
  def payload(%LogEvent{} = event, conv, type) do
    %{
      "id" => to_string(event.id),
      "type" => type,
      "created_at" => DateTime.to_iso8601(event.inserted_at),
      "data" => %{
        "conversation_id" => conv.id,
        "agent_id" => conv.agent_id,
        "parent_conversation_id" => conv.parent_conversation_id,
        "status" => conv.status,
        "stage" => event.stage,
        "state" => event.state,
        "turn_id" => event.turn_id,
        "duration_ms" => event.duration_ms
      }
    }
  end

  @doc """
  A synthetic event, so someone wiring up a receiver can see a signed request
  arrive without waiting for an agent to finish.

  Carries `type: "webhook.test"`, which is deliberately outside the
  `conversation.*` namespace: a receiver that switches on type will not
  mistake it for a real transition, and it is delivered whatever the
  endpoint's filter says.
  """
  @spec deliver_test_event(Endpoint.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def deliver_test_event(%Endpoint{} = endpoint) do
    payload = %{
      "id" => "test_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      "type" => "webhook.test",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => %{"endpoint_id" => endpoint.id}
    }

    Fountain.Workers.WebhookDelivery.enqueue(endpoint.id, payload)
  end

  @doc """
  Send one stored delivery's event again, by hand, from the console or the
  API. A fresh job with a fresh attempt counter, against the endpoint's
  current URL and current secret.
  """
  @spec redeliver(Delivery.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def redeliver(%Delivery{} = delivery) do
    Fountain.Workers.WebhookDelivery.enqueue(delivery.webhook_endpoint_id, delivery.payload)
  end

  ## ── failure bookkeeping ───────────────────────────────────────────────────

  @doc "A receiver accepted an event. Clears the consecutive-failure count."
  def note_success(%Endpoint{} = endpoint) do
    Repo.update_all(
      from(e in Endpoint, where: e.id == ^endpoint.id and e.consecutive_failures > 0),
      set: [consecutive_failures: 0]
    )

    :ok
  end

  @doc """
  An event exhausted its retries. Increments the count and, at the threshold,
  disables the endpoint and emails its owner.

  Increment and read in one statement, so two events finishing at once cannot
  both read the pre-increment value and neither trip the threshold.
  """
  def note_failure(%Endpoint{} = endpoint, reason) do
    {1, [count]} =
      Repo.update_all(
        from(e in Endpoint, where: e.id == ^endpoint.id, select: e.consecutive_failures),
        inc: [consecutive_failures: 1]
      )

    if count >= @failure_threshold and endpoint.status == "active" do
      {:ok, _} =
        disable_endpoint(
          endpoint,
          "#{count} events in a row failed to deliver (#{reason})",
          actor: actor()
        )

      Fountain.Workers.WebhookEmail.enqueue_disabled(endpoint.id)
    end

    :ok
  end

  ## ── audit ─────────────────────────────────────────────────────────────────

  # Records the URL host and the event filter, never the secret and never the
  # path or query, which a tenant can put anything in. See decisions/0013.
  defp audit(%Endpoint{} = endpoint, action, opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.merge(%{
        "host" => host_of(endpoint.url),
        "event_types" => endpoint.event_types
      })

    Audit.record(%{
      user_id: endpoint.user_id,
      action: action,
      resource_type: "webhook_endpoint",
      resource_id: endpoint.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata
    })
  end

  defp host_of(url) when is_binary(url), do: URI.parse(url).host
  defp host_of(_), do: nil

  defp merge_metadata(opts, extra) do
    Keyword.update(opts, :metadata, extra, &Map.merge(&1, extra))
  end

  defp stringify(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
