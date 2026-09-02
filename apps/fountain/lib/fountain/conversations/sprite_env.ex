defmodule Fountain.Conversations.SpriteEnv do
  @moduledoc """
  The sandbox's environment: rows and decrypted secrets in, an ordered
  `{name, value}` list out.

  One precedence rule, stated here and nowhere else: **a vault wins over an
  environment on key collision** (`merge_secrets/3`). In the assembled list
  (`build/4`) the runtime's own defaults come first and the brokered
  placeholders last, and the list is registered with
  `Fountain.Conversations.Redaction` before it is returned, so what the
  agent sees is exactly what is scrubbed from its output.

  Functions over rows and values, not over server state (#1369). Nothing
  here talks to a sandbox; the writes that carry the list into one are
  `Fountain.Conversations.Provisioning`'s.
  """

  alias Fountain.{Crypto, Environments, InferenceCredentials, Vaults}
  alias Fountain.Conversations.CallbackKey
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  # Load the per-tenant DEK and decrypted inference credentials. Both are
  # held in GenServer state for the conversation lifetime; the DEK is used
  # for ad-hoc decryption (vaults, environments) and the credentials map
  # is passed to runtime modules via build_sprite_env.
  @spec load_tenant_state(String.t()) :: {:ok, binary(), map()} | {:error, term()}
  def load_tenant_state(user_id) when is_binary(user_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, creds} <- InferenceCredentials.decrypted_for_user(user_id, dek) do
      {:ok, dek, creds}
    end
  end

  # Env secrets first, vault overrides last — vault wins on key collision.
  # Same merged map feeds repositories[].secret_key resolution.
  @spec merge_secrets(Environment.t() | nil, Vault.t() | nil, binary()) :: %{
          String.t() => String.t()
        }
  def merge_secrets(env, vault, dek) do
    env_secrets = if env, do: Environments.decrypted_env(env, dek), else: %{}
    vault_secrets = if vault, do: Vaults.decrypted_env(vault, dek), else: %{}
    Map.merge(env_secrets, vault_secrets)
  end

  @doc """
  The sandbox's environment, assembled in the order the pieces have always
  come in: the runtime's own defaults, the callback pair, the conversation
  and sandbox ids, the sandbox URL, the trace context, the git author, the
  environment's plain variables, the decrypted secrets and, last, the
  brokered placeholders.

  `opts` carries what `ConversationServer` holds: `:runtime_module`,
  `:env_credentials`, `:callback_token`, `:conversation_id` and
  `:sandbox_id`, plus `:sandbox_url` (nil before the sandbox has one) and
  `:brokered` (the placeholder pairs from the broker session, `[]` when the
  conversation is not brokered; the broker half is #1373's).
  """
  @spec build(map() | nil, Environment.t() | nil, map(), keyword()) ::
          [{String.t(), String.t()}]
  def build(agent, env, secrets, opts) do
    runtime_module = Keyword.fetch!(opts, :runtime_module)
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    sprite_env =
      (runtime_module.default_env(agent, Keyword.fetch!(opts, :env_credentials)) || []) ++
        CallbackKey.env(Keyword.fetch!(opts, :callback_token)) ++
        conversation_env(conversation_id) ++
        sandbox_id_env(Keyword.fetch!(opts, :sandbox_id)) ++
        sandbox_url_env(Keyword.get(opts, :sandbox_url)) ++
        otel_propagation_env() ++
        git_author_env() ++
        if(env,
          do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
          else: []
        ) ++
        Enum.map(secrets, fn {k, v} -> {k, v} end) ++
        Keyword.get(opts, :brokered, [])

    # Register before anything can log. Provisioning writes output from its
    # very first step, and the secrets are already in the sprite by then.
    Fountain.Conversations.Redaction.put(conversation_id, sprite_env)
    sprite_env
  end

  # The sandbox's own HTTP endpoint, so an agent asked "what's the URL?" can
  # answer. Without it the agent has no way to know: the platform assigns the
  # URL outside the sandbox, and inside it the hostname is just "sprite".
  #
  # `SANDBOX_URL` rather than `SPRITE_URL` because the value is provider-
  # neutral; a provider that has no such endpoint simply sets nothing, and an
  # unset variable is the honest answer to "no URL".
  @spec sandbox_url_env(String.t() | nil) :: [{String.t(), String.t()}]
  def sandbox_url_env(nil), do: []
  def sandbox_url_env(url) when is_binary(url), do: [{"SANDBOX_URL", url}]

  # Inject the current conversation ID so the bundled fountain skill can
  # propagate it as X-Fountain-Parent-Conversation-Id when spawning children.
  @spec conversation_env(String.t() | nil) :: [{String.t(), String.t()}]
  def conversation_env(nil), do: []

  def conversation_env(conv_id) when is_binary(conv_id),
    do: [{"FOUNTAIN_CONVERSATION_ID", conv_id}]

  # The machine's own id, so the bundled fountain skill can put a child
  # conversation onto this same sandbox (`sandbox_id` on the create, ADR 0023).
  # Machine-scoped, not conversation-scoped: every conversation on the sandbox
  # sees the same value, so unlike the conversation id it may live on the disk.
  @spec sandbox_id_env(String.t() | nil) :: [{String.t(), String.t()}]
  def sandbox_id_env(nil), do: []

  def sandbox_id_env(sandbox_id) when is_binary(sandbox_id),
    do: [{"FOUNTAIN_SANDBOX_ID", sandbox_id}]

  @doc false
  def git_author_env do
    [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end

  # Inject the W3C trace context as TRACEPARENT into the sprite env when
  # we're inside an active OTel span. claude / codex / gemini / opencode
  # all read TRACEPARENT and tag their API calls into the trace, so a
  # turn span has every model API request as a child.
  @spec otel_propagation_env() :: [{String.t(), String.t()}]
  def otel_propagation_env do
    case Fountain.Telemetry.current_traceparent() do
      nil -> []
      tp -> [{"TRACEPARENT", tp}]
    end
  end
end
