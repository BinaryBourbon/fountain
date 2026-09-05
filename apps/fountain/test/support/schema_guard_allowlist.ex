defmodule FountainWeb.SchemaGuardAllowlist do
  @moduledoc """
  What the schema guard is allowed to find today, and why.

  The ratchet this repository already uses for the docs prose gates
  (`scripts/docs-style-allow.txt`) and for the omissions list in
  `sdk/contract`: write down what is wrong now, forbid anything new, and let
  the list only shrink. Every entry is one `{operation, status}` pair — never a
  pattern — so a second operation with the same defect fails until somebody
  decides about it too. That is the whole point: the families below are
  systemic, and a wildcard would let the next instance in unnoticed.

  Cleaning one up means deleting its line. `FountainWeb.SchemaGuardrailTest`
  fails if the list grows past `@ceiling`, so growing it is a deliberate edit a
  reviewer sees.

  ## An extension's operations do not belong here

  This list is core's, and only core's. `apps/fountain` installs no extension
  (ADR 0043, and `config/runtime.exs` asks `Code.ensure_loaded?/1`), so the
  staleness check in `SchemaGuardrailTest` — "every entry names an operation
  the API still serves" — cannot see an extension operation and reports any
  entry naming one as stale.

  That is not a hypothetical. `{"POST /api/support/reports", 401}` sat here
  until #1528 deleted it as stale, and it was not stale: the operation had
  simply moved into `apps/fountain_support`, where nothing checked it either,
  because the schema guard could not resolve through `ExtensionDispatch` at all
  until #1536. A ratchet cannot count what it cannot see, and the entry looked
  like a fix landing.

  So an extension declares the statuses on its own operations instead — there
  were 8 of them across both extensions, against the 66 core operations #1432
  still owes. `FountainWeb.ExtensionSchemaGuardCase` enforces it from each
  extension's suite, which is the only run that can.

  ## The families

  `:plug_status` — the operation does not declare a status something in the
  pipeline can return on any route. `Plugs.TenantAPIAuth` answers 401,
  `require_admin` 403, `Plugs.RateLimit` 429, an unready sandbox 503,
  `plug :accepts` 406. The document describes controllers; these come from
  plugs, which is why 68 of them appear at once. Declaring each per operation
  is a large, mechanical documentation change (#1432).

  `:mixed_422_shapes` — the operation declares `ChangesetError` for 422, which
  requires `errors`, and can also refuse with a coded
  `%{error: ..., message: ...}` that has none. Since #1431 both bodies carry
  `error`, so the question left is what such an operation should declare;
  #1444 has the three answers and why it is an API decision rather than a fix.

  `:test_fixture_vocabulary` — not a defect in the API. The fixture inserts a
  value on purpose that the domain no longer accepts (a conversation whose
  runtime is `retired-runtime`, exercising the retired-runtime path), so the
  rendered enum is out of vocabulary because the test asked for that.
  """

  @reasons %{
    plug_status: "a status a pipeline plug returns that the operation does not declare (#1432)",
    mixed_422_shapes: "declares ChangesetError for 422 but can also refuse with a code (#1444)",
    test_fixture_vocabulary: "the fixture inserts an out-of-vocabulary value on purpose"
  }

  # The list may shrink, never grow, without a deliberate edit here and in the
  # guardrail's own ceiling.
  @entries %{
    # ── plug_status (66) ─────────────────────────────
    {"DELETE /api/account", 401} => :plug_status,
    {"DELETE /api/agents/{id}", 401} => :plug_status,
    {"DELETE /api/conversations/{id}", 401} => :plug_status,
    {"DELETE /api/environments/{id}", 401} => :plug_status,
    {"DELETE /api/vaults/{id}", 401} => :plug_status,
    {"GET /api/account/billing", 401} => :plug_status,
    {"GET /api/account/inference-credentials", 401} => :plug_status,
    {"GET /api/admin/users", 401} => :plug_status,
    {"GET /api/admin/users", 422} => :plug_status,
    {"GET /api/agents", 401} => :plug_status,
    {"GET /api/agents", 429} => :plug_status,
    {"GET /api/agents/{id}", 401} => :plug_status,
    {"GET /api/agents/{id}/avatar", 401} => :plug_status,
    {"GET /api/agents/{id}/versions", 401} => :plug_status,
    {"GET /api/agents/{id}/versions/{version}", 422} => :plug_status,
    {"GET /api/audit", 401} => :plug_status,
    {"GET /api/catalog", 401} => :plug_status,
    {"GET /api/connection-providers", 403} => :plug_status,
    {"GET /api/connections", 403} => :plug_status,
    {"GET /api/conversations", 401} => :plug_status,
    {"GET /api/conversations", 406} => :plug_status,
    {"GET /api/conversations/{conversation_id}/events", 401} => :plug_status,
    {"GET /api/conversations/{conversation_id}/events", 422} => :plug_status,
    {"GET /api/conversations/{conversation_id}/stream", 401} => :plug_status,
    {"GET /api/conversations/{conversation_id}/tree", 401} => :plug_status,
    {"GET /api/conversations/{conversation_id}/turns/{turn_id}/images/{position}", 401} =>
      :plug_status,
    {"GET /api/conversations/{id}", 401} => :plug_status,
    {"GET /api/environments", 401} => :plug_status,
    {"GET /api/environments/{environment_id}/secrets", 401} => :plug_status,
    {"GET /api/environments/{id}", 401} => :plug_status,
    {"GET /api/sandboxes/{sandbox_id}/file", 403} => :plug_status,
    {"GET /api/sandboxes/{sandbox_id}/files", 403} => :plug_status,
    {"GET /api/search", 401} => :plug_status,
    {"GET /api/team", 401} => :plug_status,
    {"GET /api/team/schedules", 401} => :plug_status,
    {"GET /api/vaults", 401} => :plug_status,
    {"GET /api/vaults/{id}", 401} => :plug_status,
    {"GET /api/webhooks", 403} => :plug_status,
    {"GET /v1/models", 404} => :plug_status,
    {"POST /api/account/onboarding/complete", 401} => :plug_status,
    {"POST /api/agents", 401} => :plug_status,
    {"POST /api/agui/{agent_id}", 401} => :plug_status,
    {"POST /api/agui/{agent_id}", 409} => :plug_status,
    {"POST /api/apply", 401} => :plug_status,
    {"POST /api/auth/token", 429} => :plug_status,
    {"POST /api/avatars/generate", 400} => :plug_status,
    {"POST /api/conversations", 400} => :plug_status,
    {"POST /api/conversations", 409} => :plug_status,
    {"POST /api/conversations", 429} => :plug_status,
    {"POST /api/conversations", 503} => :plug_status,
    {"POST /api/conversations/{conversation_id}/interrupt", 503} => :plug_status,
    {"POST /api/conversations/{conversation_id}/prompts", 402} => :plug_status,
    {"POST /api/conversations/{conversation_id}/prompts", 410} => :plug_status,
    {"POST /api/conversations/{conversation_id}/prompts", 422} => :plug_status,
    {"POST /api/conversations/{conversation_id}/prompts", 429} => :plug_status,
    {"POST /api/conversations/{conversation_id}/prompts", 503} => :plug_status,
    {"POST /api/conversations/{conversation_id}/terminate", 503} => :plug_status,
    {"POST /api/environments", 401} => :plug_status,
    {"POST /api/team/{agent_id}/contact", 424} => :plug_status,
    {"POST /api/vaults", 401} => :plug_status,
    {"POST /api/webhooks", 403} => :plug_status,
    {"POST /v1/chat/completions", 401} => :plug_status,
    {"POST /v1/chat/completions", 500} => :plug_status,
    {"PUT /api/agents/{id}", 401} => :plug_status,
    {"PUT /api/environments/{id}", 401} => :plug_status,
    {"PUT /api/vaults/{id}", 401} => :plug_status,

    # ── mixed_422_shapes (2) ─────────────────────────────
    {"POST /api/auth/register", 422} => :mixed_422_shapes,
    {"POST /api/conversations", 422} => :mixed_422_shapes,

    # ── test_fixture_vocabulary (1) ─────────────────────────────
    {"GET /api/conversations/{id}", 200} => :test_fixture_vocabulary
  }

  @doc "Is this `{operation, status}` a known, recorded disagreement?"
  @spec allowed?(String.t(), integer()) :: boolean()
  def allowed?(operation, status), do: Map.has_key?(@entries, {operation, status})

  @doc "The reason family for one entry, or nil."
  @spec reason(String.t(), integer()) :: String.t() | nil
  def reason(operation, status) do
    case Map.get(@entries, {operation, status}) do
      nil -> nil
      family -> Map.fetch!(@reasons, family)
    end
  end

  @doc "Every entry, for the guardrail's hygiene checks."
  @spec entries() :: %{{String.t(), integer()} => atom()}
  def entries, do: @entries

  @doc "The families and their prose."
  @spec reasons() :: %{atom() => String.t()}
  def reasons, do: @reasons
end
