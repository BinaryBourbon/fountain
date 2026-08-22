defmodule FountainWeb.SchemaEnumGuardrailTest do
  @moduledoc """
  The OpenAPI enums against the domain lists they restate (issue #599).

  `FountainWeb.Schemas` declares every enum a second time, by hand. Twelve
  lists were duplicated verbatim from an Ecto schema — `agent.runtime` alone
  in four places — and nothing checked that the copies agreed. The drift is
  silent in the worst direction: add a value to `@statuses` and the changeset
  accepts it, the API returns it, the spec says it cannot exist,
  `mix openapi.spec.json` still passes, and only a generated client with a
  strict enum decoder finds out, in production. #197 is the precedent — the
  unreachable `completed` conversation status stayed in the published enum
  after the schema dropped it.

  This walks every `FountainWeb.Schemas.*` module, finds every property
  carrying an `:enum`, and requires each one to be either

    * mapped in `@derived` to the domain function that owns the list, and
      equal to it; or
    * listed in `@api_local` with a reason — an enum with no domain
      counterpart, which is a decision rather than an oversight.

  Add an enum to a schema and this test fails until you do one or the other.
  Comparison is by set: OpenAPI enum order is not meaningful, and two of
  these lists were already written in a different order than their source
  (`~w(admin user)` against `User.roles/0`'s `~w(user admin)`).
  """

  use ExUnit.Case, async: true

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Buzz.BuzzIdentity
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}
  alias Fountain.Environments.Environment
  alias Fountain.Exports.Export
  alias Fountain.InferenceCredentials.Credential
  alias Fountain.{Accounts, Images, Manifest}
  alias OpenApiSpex.Schema

  # {schema module, dotted property path} => {owning module, function}
  #
  # The value is compared as a set against `apply(mod, fun, [])`. A provider
  # list of atoms is stringified first — the domain keeps them as atoms, the
  # wire carries strings.
  @derived %{
    {FountainWeb.Schemas.AdminRoleRequest, "role"} => {User, :roles},
    {FountainWeb.Schemas.AdminUser, "role"} => {User, :roles},
    {FountainWeb.Schemas.AuthMeResponse, "role"} => {User, :roles},
    {FountainWeb.Schemas.Agent, "runtime"} => {Agent, :runtimes},
    {FountainWeb.Schemas.AgentRequest, "runtime"} => {Agent, :runtimes},
    {FountainWeb.Schemas.AgentUpdate, "runtime"} => {Agent, :runtimes},
    {FountainWeb.Schemas.Agent, "sandbox_provider"} => {Fountain.Sandbox, :known_providers},
    {FountainWeb.Schemas.Sandbox, "provider"} => {Fountain.Sandbox, :known_providers},
    {FountainWeb.Schemas.AgentRequest, "sandbox_provider"} =>
      {Fountain.Sandbox, :known_providers},
    {FountainWeb.Schemas.AgentUpdate, "sandbox_provider"} => {Fountain.Sandbox, :known_providers},
    # A conversation's runtime is copied from its agent at spawn, so it must
    # speak the same vocabulary even though the column carries no inclusion
    # validation of its own.
    {FountainWeb.Schemas.Conversation, "runtime"} => {Agent, :runtimes},
    {FountainWeb.Schemas.Agent, "avatar_media_type"} => {Images, :valid_media_types},
    {FountainWeb.Schemas.AvatarRequest, "media_type"} => {Images, :valid_media_types},
    {FountainWeb.Schemas.ImageInput, "media_type"} => {Images, :valid_media_types},
    {FountainWeb.Schemas.BillingResponse, "data.status"} => {User, :subscription_statuses},
    {FountainWeb.Schemas.AdminUser, "plan"} => {Fountain.Plans, :slugs},
    {FountainWeb.Schemas.BillingResponse, "data.plan.slug"} => {Fountain.Plans, :slugs},
    {FountainWeb.Schemas.BuzzIdentity, "respond_to"} => {BuzzIdentity, :respond_to_modes},
    {FountainWeb.Schemas.BuzzProvisionRequest, "respond_to"} => {BuzzIdentity, :respond_to_modes},
    {FountainWeb.Schemas.BuzzAccessUpdateRequest, "respond_to"} =>
      {BuzzIdentity, :respond_to_modes},
    # The permission verdicts a policy may actually name today. Deliberately
    # `buildable_verdicts/0` and not `verdicts/0`: "ask" is a real verdict the
    # domain knows about, with nowhere to ask until #940, and both doors refuse
    # it — so publishing it in the spec would advertise a value every request
    # carrying it gets a 422 for.
    {FountainWeb.Schemas.Agent, "permission_policy.{}"} =>
      {Fountain.Permissions, :buildable_verdicts},
    {FountainWeb.Schemas.ConversationCreateRequest, "permission_policy.{}"} =>
      {Fountain.Permissions, :buildable_verdicts},
    {FountainWeb.Schemas.AgentRequest, "permission_policy.{}"} =>
      {Fountain.Permissions, :buildable_verdicts},
    {FountainWeb.Schemas.AgentUpdate, "permission_policy.{}"} =>
      {Fountain.Permissions, :buildable_verdicts},
    {FountainWeb.Schemas.Conversation, "permission_policy.{}"} =>
      {Fountain.Permissions, :buildable_verdicts},
    {FountainWeb.Schemas.Conversation, "status"} => {Conversation, :statuses},
    {FountainWeb.Schemas.Conversation, "source"} => {Conversation, :sources},
    {FountainWeb.Schemas.ConversationTreeNode, "status"} => {Conversation, :statuses},
    {FountainWeb.Schemas.ConversationTreeNode, "source"} => {Conversation, :sources},
    {FountainWeb.Schemas.Environment, "networking_type"} => {Environment, :networking},
    {FountainWeb.Schemas.EnvironmentRequest, "networking_type"} => {Environment, :networking},
    {FountainWeb.Schemas.EnvironmentUpdate, "networking_type"} => {Environment, :networking},
    {FountainWeb.Schemas.Export, "status"} => {Export, :statuses},
    {FountainWeb.Schemas.InferenceCredentialStatus, "provider"} => {Credential, :providers},
    {FountainWeb.Schemas.LogEvent, "kind"} => {LogEvent, :kinds},
    {FountainWeb.Schemas.LogEvent, "state"} => {LogEvent, :states},
    {FountainWeb.Schemas.ManifestResource, "kind"} => {Manifest, :kinds},
    {FountainWeb.Schemas.OnboardingResponse, "data.state"} => {Accounts, :onboarding_states},
    {FountainWeb.Schemas.Sandbox, "status"} => {Sandbox, :statuses},
    {FountainWeb.Schemas.Turn, "status"} => {Turn, :statuses},
    {FountainWeb.Schemas.Teammate, "presence.state"} =>
      {FountainWeb.TeamPresenter, :presence_states},
    {FountainWeb.Schemas.Teammate, "preview.kind"} => {FountainWeb.TeamPresenter, :preview_kinds},
    {FountainWeb.Schemas.Block, "kind"} => {Fountain.Conversations.Blocks, :kinds},
    {FountainWeb.Schemas.SearchHit, "kind"} => {Fountain.Search, :kinds},
    {FountainWeb.Schemas.SupportReport, "category"} => {Fountain.Support.Report, :categories},
    {FountainWeb.Schemas.SupportReport, "status"} => {Fountain.Support.Report, :statuses},
    {FountainWeb.Schemas.SupportReportCreateRequest, "category"} =>
      {Fountain.Support.Report, :categories},
    {FountainWeb.Schemas.SupportReportCreateRequest, "screenshot.media_type"} =>
      {Fountain.Images, :valid_media_types},
    {FountainWeb.Schemas.WebhookEndpoint, "status"} => {Fountain.Webhooks.Endpoint, :statuses},
    {FountainWeb.Schemas.WebhookEndpointUpdateRequest, "status"} =>
      {Fountain.Webhooks.Endpoint, :statuses}
  }

  # Enums with no domain list behind them. Each entry needs a reason: the
  # point of the list is that adding to it is a deliberate act.
  @api_local %{
    # Outcomes of two admin actions. Computed in the controller from what the
    # action did; they describe an HTTP response, not a stored value.
    {FountainWeb.Schemas.AdminReapResponse, "data.outcome"} =>
      "admin reap result — response vocabulary, not persisted state",
    {FountainWeb.Schemas.AdminResyncResponse, "data.outcome"} =>
      "admin resync result — response vocabulary, not persisted state",
    # Per-resource results from `fountain apply`. Manifest reports these as
    # atoms built inline per branch; there is no list to compare against.
    {FountainWeb.Schemas.ApplyResult, "action"} =>
      "manifest apply outcome — built per branch in Manifest, not a declared list",
    {FountainWeb.Schemas.ApplySecretResult, "action"} =>
      "manifest secret apply outcome — as above",
    # Health probe vocabulary, owned by the readiness endpoint.
    {FountainWeb.Schemas.ReadinessResponse, "status"} => "health probe vocabulary",
    {FountainWeb.Schemas.ReadinessResponse, "checks.{}"} => "health probe vocabulary"
  }

  # Domain lists that are exposed on the wire but deliberately carry no enum
  # in the spec. Recorded here so the omission stays a decision — this test
  # cannot catch drift in a field it does not constrain.
  #
  #   LogEvent.stream (LogEvent.streams/0 == ~w(stdout stderr)) — stage events
  #   carry "" for this field, so the honest enum would be
  #   ["stdout", "stderr", ""]. Left unconstrained with a prose description
  #   instead. Revisit if stage events stop sharing the shape.

  describe "every OpenAPI enum is accounted for" do
    setup do
      %{sites: enum_sites()}
    end

    test "each enum matches the domain list it restates", %{sites: sites} do
      mismatches =
        for {mod, path, enum} <- sites,
            {owner, fun} = Map.get(@derived, {mod, path}, {nil, nil}),
            owner != nil,
            expected = owner |> apply(fun, []) |> Enum.map(&to_string/1) |> MapSet.new(),
            actual = enum |> Enum.map(&to_string/1) |> MapSet.new(),
            not MapSet.equal?(expected, actual) do
          """
            #{short(mod)}.#{path}
              spec has:   #{inspect(Enum.sort(actual))}
              #{inspect(owner)}.#{fun}/0 has: #{inspect(Enum.sort(expected))}
              only in spec:   #{inspect(actual |> MapSet.difference(expected) |> Enum.sort())}
              only in domain: #{inspect(expected |> MapSet.difference(actual) |> Enum.sort())}
          """
        end

      assert mismatches == [],
             "OpenAPI enums have drifted from the domain lists they restate:\n\n" <>
               Enum.join(mismatches, "\n")
    end

    test "no enum is unclassified", %{sites: sites} do
      unclassified =
        for {mod, path, enum} <- sites,
            not Map.has_key?(@derived, {mod, path}),
            not Map.has_key?(@api_local, {mod, path}),
            do: "  #{short(mod)}.#{path} => #{inspect(enum)}"

      assert unclassified == [],
             """
             New OpenAPI enum(s) with no declared source:

             #{Enum.join(unclassified, "\n")}

             Add each to @derived pointing at the domain function that owns the
             list, or to @api_local with a reason if it has no domain counterpart.
             """
    end

    test "the registries have no stale entries", %{sites: sites} do
      live = MapSet.new(sites, fn {mod, path, _} -> {mod, path} end)

      stale =
        (Map.keys(@derived) ++ Map.keys(@api_local))
        |> Enum.reject(&MapSet.member?(live, &1))
        |> Enum.map(fn {mod, path} -> "  #{short(mod)}.#{path}" end)

      assert stale == [],
             "Registry entries pointing at enums that no longer exist:\n" <>
               Enum.join(stale, "\n")
    end
  end

  # Every enum reachable from a schema, as {module, dotted path, values}.
  defp enum_sites do
    :fountain
    |> :application.get_key(:modules)
    |> elem(1)
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.FountainWeb.Schemas."))
    |> Enum.sort()
    |> Enum.flat_map(fn mod ->
      Code.ensure_loaded(mod)

      if function_exported?(mod, :schema, 0) do
        mod.schema() |> walk([]) |> Enum.map(fn {path, enum} -> {mod, path, enum} end)
      else
        []
      end
    end)
  end

  # `properties` values may be a %Schema{}, a nested schema module (a $ref),
  # or a bare type atom. Only inline %Schema{} structs are walked — a module
  # reference is that module's own responsibility and is visited on its own.
  defp walk(%Schema{} = schema, path) do
    own =
      if is_list(schema.enum),
        do: [{path |> Enum.reverse() |> Enum.join("."), schema.enum}],
        else: []

    own ++
      walk_props(schema.properties, path) ++
      walk(schema.items, ["[]" | path]) ++
      walk(schema.additionalProperties, ["{}" | path]) ++
      Enum.flat_map(schema.oneOf || [], &walk(&1, path)) ++
      Enum.flat_map(schema.allOf || [], &walk(&1, path))
  end

  defp walk(_, _), do: []

  defp walk_props(props, path) when is_map(props),
    do: Enum.flat_map(props, fn {key, value} -> walk(value, [to_string(key) | path]) end)

  defp walk_props(_, _), do: []

  defp short(mod), do: mod |> inspect() |> String.replace("FountainWeb.Schemas.", "")
end
