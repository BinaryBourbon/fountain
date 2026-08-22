defmodule Fountain.Analytics do
  @moduledoc """
  Product analytics: what people do with Fountain, captured into PostHog.

  This is the *product* sink, and it is the third of three that already
  existed and kept answering different questions:

    * `Fountain.Audit` — who changed what, kept forever, tenant-visible. A
      compliance record, not a metric.
    * `Fountain.Billing.record_usage/5` — what to charge for. Six event types,
      shaped by the invoice.
    * OTel spans / `Fountain.Telemetry` — how the machine is behaving.

  None of them answers "did the people who verified last week come back", so
  the funnel was hand-rolled in SQL (`Fountain.Funnel`) and everything past
  the funnel was unanswerable. This module sends the same events PostHog can
  slice, retain and cohort without anyone writing a query first.

  ## The events come from choke points, not from call sites

  The same argument the audit trail makes (ADR 0013): a call site that has to
  remember to instrument is a call site that will not. Every event below is
  emitted from a function that *already* had to be called for the thing to
  have happened, so a new door onto an existing action is instrumented by
  construction:

  | Choke point | Events |
  |---|---|
  | `Fountain.Audit.record/1` | every audited mutation, under its own action name (`agent.created`, `vault.secret.write`, …) |
  | `Fountain.Billing.record_usage/5` | `usage.sandbox_provisioned`, `usage.turn_started`, `usage.sandbox_terminated`, … |
  | `Fountain.Conversations.publish_stage/4` | `conversation.turn.done` and the other outcome stages webhooks already subscribe to |
  | `FountainWeb.Live.Hooks` | `$pageview` for the console |
  | `Fountain.FeatureFlags` | `$feature_flag_called`, plus `$feature/<key>` on every other event |

  Adding an instrumented action means adding an audit call — which the
  guardrail test already requires — and nothing else.

  ## It is best-effort, and it is off by default

  `capture/4` casts to `Fountain.Analytics.Sink` and returns `:ok` before any
  HTTP happens. Nothing here can slow down, fail, or roll back the operation
  it describes; a full queue drops events and says so in telemetry rather
  than growing without bound.

  With no `POSTHOG_PROJECT_API_KEY` the whole module is inert — a self-hoster
  who never sets one sends nothing, ever. When a key *is* set it is the
  operator's own PostHog project, which is also why person properties carry
  the account's email by default; `POSTHOG_PERSON_PII=false` turns that off
  and leaves the user id, which is what the audit trail stores anyway.

  ## What is deliberately not sent

    * **Secret values, env var values, prompts and agent output.** The audit
      rule (never record values, only keys and sizes) is the same rule here,
      and `sanitize/1` enforces it on anything arriving from audit metadata.
    * **Per-chunk conversation output.** A chatty turn writes thousands of
      stdout events; the same reason `Fountain.Webhooks.Events` refuses to
      dispatch `kind: "output"` applies to a capture endpoint.
    * **Anonymous events.** An event with no user is dropped rather than
      given a synthetic id, so PostHog person counts mean accounts.
  """

  require Logger

  alias Fountain.Analytics.Sink
  alias Fountain.Accounts.User

  @typedoc "Anything that can name the person an event belongs to."
  @type subject :: User.t() | %{id: String.t()} | String.t() | nil

  @lib "fountain-elixir"

  # PostHog group analytics, one group type: the deployment. Every event
  # carries it, so a hosted instance and a self-hoster reporting into the same
  # project stay separable, and instance-level properties (version, provider
  # mix) can be set once instead of on every person.
  @group_type "instance"

  ## Public API

  @doc """
  Whether capture is on: a project API key is configured and
  `POSTHOG_CAPTURE` has not turned it off.

  `Fountain.FeatureFlags.configured?/0` answers the same question for the
  *flag* half of the same key — an operator can evaluate flags without
  sending product events, but not the other way round.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Fountain.FeatureFlags.configured?() and
      Application.get_env(:fountain, :analytics_enabled, true) != false
  end

  @doc """
  Capture one event for one person.

  `subject` is a `%User{}`, a user id, or `nil`; a `nil` subject with no
  `:distinct_id` option is dropped (see the moduledoc). Returns `:ok` in
  every case, including when analytics is off — callers are choke points on
  the hot path and must never branch on this.

  ## Options

    * `:distinct_id` — override the person id (the only way to capture for a
      subject that is not a user row, e.g. a boot-time instance event).
    * `:timestamp` — event time; defaults to now, which matters because the
      sink batches.
    * `:request_ip` — the *end user's* IP, forwarded as `$ip` so PostHog
      geolocates the person rather than the server.
    * `:set` / `:set_once` — person properties to merge on this event.
    * `:groups` — extra group associations beyond the instance group.
  """
  @spec capture(String.t(), subject(), map(), keyword()) :: :ok
  def capture(event, subject, properties \\ %{}, opts \\ [])

  def capture(event, subject, properties, opts) when is_binary(event) do
    with true <- enabled?(),
         id when is_binary(id) <- distinct_id(subject, opts) do
      Sink.enqueue(payload(event, id, properties, opts))
    else
      _ -> :ok
    end
  rescue
    # A capture that raises must not take the operation with it. This is the
    # same contract `Audit.record/1` keeps, for the same reason.
    e ->
      Logger.warning("analytics: capture #{event} failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Send the account's current shape to PostHog as person properties.

  Called wherever the shape changes in a way a cohort would care about
  (registration, verification, onboarding, a subscription transition), not on
  every request — person property writes are the expensive half of ingestion
  and the properties only change on those events.
  """
  @spec identify(subject(), map()) :: :ok
  def identify(subject, extra \\ %{})

  def identify(%{__struct__: User} = user, extra) do
    capture("$identify", user, %{},
      set: Map.merge(person_properties(user), extra),
      set_once: set_once_properties(user)
    )
  end

  def identify(_subject, _extra), do: :ok

  @doc """
  Associate the deployment group with its current properties.

  Sent once per boot from `Fountain.Analytics.Sink`; group properties are
  last-write-wins, so a rolling deploy converges on the new version.
  """
  @spec identify_instance(map()) :: :ok
  def identify_instance(properties \\ %{}) do
    capture(
      "$groupidentify",
      nil,
      %{
        "$group_type" => @group_type,
        "$group_key" => instance(),
        "$group_set" => Map.merge(instance_properties(), properties)
      },
      distinct_id: "instance:#{instance()}"
    )
  end

  # A context action name: dotted, lowercase, closed vocabulary
  # (`agent.created`, `team.contact.provisioned`). Anything else arriving from
  # the audit trail is the `:api` pipeline's request-log row, which is named
  # after the request line and carries a UUID.
  @context_action ~r/^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/

  # The two surfaces a person mints an API key from. Everything else is a
  # credential the system issued itself.
  @human_actors ~w(ui api)

  @doc """
  Whether an audited action belongs in PostHog.

  The audit trail and a product analytics stream want different things, and
  mirroring one into the other wholesale was wrong in two ways that a day of
  production data made obvious (2,160 audit rows in 24 hours).

  ## The request log is not a product event

  ADR 0013 §4 keeps a **second** row for every API mutation, written by the
  `:api` pipeline plug and named after the request line
  (`POST /api/conversations/<uuid>/read`). It answers "what was attempted",
  including for requests that were refused, which is what an access log is
  for. The semantic row for the same mutation (`conversation.created`) is
  already captured, so nothing is lost by declining the second one.

  What would be lost by keeping it is the event taxonomy. Those names embed
  resource ids: **73 distinct action names in one day**, every one of which
  PostHog registers as its own event definition, permanently. A product
  vocabulary has to be closed, and `@context_action` is that fence.

  ## A credential the system issued itself is not a product event

  `api_key.created` and `api_key.revoked` were **1,513 of those 2,160 rows —
  70% of the entire trail**. Not one carried a human actor: 534 `self`
  (the context default, which OAuth token issuance takes — a Fountain OAuth
  token *is* an API key, ADR 0021), 445 `system:conversation_server`, 341
  `system:buzz_harness`, 193 `system:buzz_boot_sweep`. Those are sprite
  credentials minted and revoked per conversation and per harness boot. They
  say how busy the machine is, which is a telemetry question, and they would
  have drowned every real signal in the project.

  A person minting a key in the console or through the API is genuine product
  usage and is kept: both call sites pass `FountainWeb.Audited.attribution/2`,
  so they arrive as `ui` or `api`.

  This filter never touches what is *audited*. The trail keeps every row.
  """
  @spec product_event?(String.t(), String.t() | nil) :: boolean()
  def product_event?(action, actor) when is_binary(action) do
    cond do
      not Regex.match?(@context_action, action) -> false
      String.starts_with?(action, "api_key.") -> actor in @human_actors
      true -> true
    end
  end

  def product_event?(_action, _actor), do: false

  @doc """
  Person properties derived from a user row.

  Everything here is a fact about the *account*, never about its content:
  no agent names, no vault keys, no conversation text.
  """
  @spec person_properties(User.t()) :: map()
  def person_properties(%{__struct__: User} = user) do
    %{
      "role" => user.role,
      "subscription_status" => user.subscription_status,
      "email_verified" => not is_nil(user.email_verified_at),
      "onboarded" => not is_nil(user.onboarding_completed_at),
      "onboarding_state" => user.onboarding_state,
      "suspended" => not is_nil(user.suspended_at),
      "cancel_at_period_end" => user.cancel_at_period_end,
      "trial_ends_at" => iso(user.trial_ends_at),
      "current_period_end" => iso(user.current_period_end),
      "plan" => Fountain.Plans.resolve(user.plan).slug,
      "max_concurrent_sandboxes" => Fountain.Quotas.sandbox_limit_for(user),
      "sandbox_limit_override" => user.sandbox_limit_override,
      "has_stripe_customer" => not is_nil(user.stripe_customer_id)
    }
    |> with_pii(user)
  end

  # The email is the only field here PostHog does not need and a person
  # browsing the project *will* see. It goes to the operator's own project
  # and makes a person searchable by the address support was contacted from,
  # which is why it defaults on — but a deployment that would rather hold
  # pseudonymous persons sets POSTHOG_PERSON_PII=false and loses nothing else.
  defp with_pii(props, user) do
    if Application.get_env(:fountain, :analytics_person_pii, true) != false do
      Map.merge(props, %{"email" => user.email, "$email" => user.email})
    else
      props
    end
  end

  defp set_once_properties(%{__struct__: User} = user) do
    %{"signed_up_at" => iso(user.inserted_at)}
  end

  @doc """
  Strip an audit/metering metadata map down to what may leave the building.

  Audit metadata is already values-free by rule (ADR 0013), so this is a
  second fence rather than the first: it drops anything that is not a scalar,
  truncates long strings, and refuses keys that name a secret even though
  none should reach it.
  """
  @spec sanitize(map() | nil) :: map()
  def sanitize(nil), do: %{}

  def sanitize(metadata) when is_map(metadata) do
    metadata
    |> Enum.flat_map(fn {k, v} ->
      key = to_string(k)

      cond do
        secretish?(key, v) -> []
        scalar?(v) -> [{key, truncate(v)}]
        is_list(v) -> [{key, length(v)}]
        is_map(v) -> [{key, map_size(v)}]
        true -> []
      end
    end)
    |> Map.new()
  end

  def sanitize(_), do: %{}

  @secretish ~w(value secret token password key credential prompt content body output)

  # Only strings are refused. A count, a byte size or a boolean under one of
  # these names — `value_bytes`, `secret_count`, `has_token` — is exactly the
  # shape the audit trail is required to record instead of the value, so
  # dropping it here would throw away the safe half of the convention and
  # leave the events unable to say how big anything was.
  defp secretish?(key, value) when is_binary(value) do
    down = String.downcase(key)
    Enum.any?(@secretish, &String.contains?(down, &1))
  end

  defp secretish?(_key, _value), do: false

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_atom(v)

  defp truncate(v) when is_binary(v) and byte_size(v) > 200,
    do: binary_part(v, 0, 200) <> "…"

  defp truncate(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp truncate(v), do: v

  ## Payload construction

  defp payload(event, distinct_id, properties, opts) do
    %{
      event: event,
      distinct_id: distinct_id,
      timestamp: opts |> Keyword.get(:timestamp, DateTime.utc_now()) |> DateTime.to_iso8601(),
      properties:
        properties
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.merge(base_properties(distinct_id, opts))
        |> maybe_put("$set", Keyword.get(opts, :set))
        |> maybe_put("$set_once", Keyword.get(opts, :set_once))
    }
  end

  defp base_properties(distinct_id, opts) do
    %{
      "$lib" => @lib,
      "$lib_version" => version(),
      "$groups" => Map.merge(%{@group_type => instance()}, Keyword.get(opts, :groups, %{})),
      # Without this PostHog geolocates whichever pod sent the batch and every
      # person in the project appears to live in one datacentre. `nil` means
      # "no location"; a request-scoped caller passes the real client IP.
      "$ip" => Keyword.get(opts, :request_ip),
      "environment" => env()
    }
    |> Map.merge(feature_flag_properties(distinct_id))
  end

  # `$feature/<key>` is what makes "did the flagged cohort behave differently"
  # answerable in PostHog without re-deriving the flag at query time. Read from
  # the FeatureFlags ETS cache only — a cache miss means no HTTP and no
  # properties, because an analytics event must never be the thing that makes
  # a flag lookup happen.
  defp feature_flag_properties(distinct_id) do
    case Fountain.FeatureFlags.cached_flags(distinct_id) do
      flags when map_size(flags) > 0 ->
        Map.new(flags, fn {key, value} -> {"$feature/#{key}", value} end)

      _ ->
        %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, empty) when map_size(empty) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp distinct_id(nil, opts), do: Keyword.get(opts, :distinct_id)
  defp distinct_id(%{id: id}, _opts) when is_binary(id), do: id
  defp distinct_id(id, _opts) when is_binary(id), do: id
  defp distinct_id(_, opts), do: Keyword.get(opts, :distinct_id)

  ## Configuration

  @doc false
  def instance do
    Application.get_env(:fountain, :analytics_instance) ||
      System.get_env("PHX_HOST") || "localhost"
  end

  defp instance_properties do
    %{
      "name" => instance(),
      "version" => version(),
      "environment" => env(),
      "sandbox_providers" =>
        Enum.map_join(Fountain.Sandbox.enabled_providers(), ",", &to_string/1)
    }
  rescue
    _ -> %{"name" => instance(), "version" => version(), "environment" => env()}
  end

  # Baked at compile time on purpose: `Mix.env/0` does not exist in a release,
  # and the build env is the fact we want anyway ("what was this image built
  # as"), not whatever a runtime caller happens to be doing.
  @env to_string(Mix.env())

  defp env, do: @env

  defp version do
    case Application.spec(:fountain, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso(other), do: to_string(other)
end
