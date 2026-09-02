defmodule Fountain.Conversations.SpriteEnvTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Redaction
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Environments.Environment
  alias Fountain.{Environments, Vaults}

  # A runtime module that reports what it was handed, so the test can see the
  # defaults land first and the credentials reach them.
  defmodule Runtime do
    def default_env(_agent, creds), do: [{"RUNTIME_KEY", creds[:key]}]
  end

  defmodule SilentRuntime do
    def default_env(_agent, _creds), do: nil
  end

  describe "build/4" do
    test "is the pieces in their fixed order, brokered placeholders last" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      # An atom key sorts before a binary one in a small map, so PORT comes
      # out first; both are coerced to strings on the way.
      env = %Environment{env_vars: %{"PLAIN" => "p", PORT: 8080}}

      sprite_env =
        SpriteEnv.build(nil, env, %{"DECRYPTED" => "a-decrypted-value"},
          runtime_module: Runtime,
          env_credentials: %{key: "k"},
          callback_token: "tok",
          conversation_id: conv_id,
          sandbox_id: "sb-1",
          sandbox_url: "https://sb.example",
          brokered: [{"OPENAI_API_KEY", "placeholder"}]
        )

      base = Fountain.PublicUrl.base()

      assert sprite_env ==
               [
                 {"RUNTIME_KEY", "k"},
                 {"FOUNTAIN_BASE_URL", base},
                 {"FOUNTAIN_TOKEN", "tok"},
                 {"FOUNTAIN_CONVERSATION_ID", conv_id},
                 {"FOUNTAIN_SANDBOX_ID", "sb-1"},
                 {"SANDBOX_URL", "https://sb.example"}
               ] ++
                 SpriteEnv.git_author_env() ++
                 [
                   {"PORT", "8080"},
                   {"PLAIN", "p"},
                   {"DECRYPTED", "a-decrypted-value"},
                   {"OPENAI_API_KEY", "placeholder"}
                 ]
    end

    test "a runtime with no defaults, no environment, no token and no URL contributes nothing" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      sprite_env =
        SpriteEnv.build(nil, nil, %{},
          runtime_module: SilentRuntime,
          env_credentials: %{},
          callback_token: nil,
          conversation_id: conv_id,
          sandbox_id: nil
        )

      assert sprite_env == [{"FOUNTAIN_CONVERSATION_ID", conv_id}] ++ SpriteEnv.git_author_env()
    end

    test "registers the secrets for redaction before returning" do
      conv_id = "conv-#{System.unique_integer([:positive])}"
      on_exit(fn -> Redaction.delete(conv_id) end)

      SpriteEnv.build(nil, nil, %{"LONG" => "a-value-long-enough-to-redact", "SHORT" => "ab"},
        runtime_module: SilentRuntime,
        env_credentials: %{},
        callback_token: "a-callback-token-value",
        conversation_id: conv_id,
        sandbox_id: nil
      )

      registered = Redaction.lookup(conv_id)
      assert "a-value-long-enough-to-redact" in registered
      assert "a-callback-token-value" in registered
      refute "ab" in registered
    end
  end

  describe "merge_secrets/3" do
    test "the vault wins over the environment on a key collision" do
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      env = insert_env(user_id: user.id)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "SHARED", "value" => "from-env"}, dek)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "ONLY_ENV", "value" => "e"}, dek)

      vault = insert_vault(user_id: user.id)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "SHARED", "value" => "from-vault"}, dek)
      {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "ONLY_VAULT", "value" => "v"}, dek)

      assert SpriteEnv.merge_secrets(env, vault, dek) ==
               %{"SHARED" => "from-vault", "ONLY_ENV" => "e", "ONLY_VAULT" => "v"}

      assert SpriteEnv.merge_secrets(env, nil, dek) == %{
               "SHARED" => "from-env",
               "ONLY_ENV" => "e"
             }

      assert SpriteEnv.merge_secrets(nil, vault, dek) == %{
               "SHARED" => "from-vault",
               "ONLY_VAULT" => "v"
             }

      assert SpriteEnv.merge_secrets(nil, nil, dek) == %{}
    end
  end

  describe "load_tenant_state/1" do
    test "is the tenant key and the (empty) inference credentials" do
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert {:ok, ^dek, %{}} = SpriteEnv.load_tenant_state(user.id)
    end
  end

  describe "the small pairs" do
    test "are empty for nil" do
      assert SpriteEnv.conversation_env(nil) == []
      assert SpriteEnv.sandbox_id_env(nil) == []
      assert SpriteEnv.sandbox_url_env(nil) == []
    end

    test "the otel pair is absent without a trace context" do
      # The pair is `TRACEPARENT` from `Fountain.Telemetry.current_traceparent/0`
      # when there is one. The test config installs no text-map propagator,
      # so no context can be injected here and only the absent half is
      # pinned; the present half is four lines that moved verbatim.
      assert SpriteEnv.otel_propagation_env() == []
    end
  end
end
