defmodule Fountain.PlatformInferenceTest do
  @moduledoc """
  The platform keys, the selection rule and the daily ceiling (#1388).

  `async: false` throughout: platform keys and the ceiling live in the global
  application environment, and an async module that writes it races every
  other module that reads it (#1214).
  """

  use Fountain.DataCase, async: false

  alias Fountain.Credits
  alias Fountain.InferenceCredentials
  alias Fountain.PlatformInference

  setup do
    original =
      for key <- [
            :platform_anthropic_api_key,
            :platform_openai_api_key,
            :platform_gemini_api_key,
            :platform_inference_daily_cents
          ],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    :ok
  end

  defp with_platform_key(provider \\ :platform_anthropic_api_key, key \\ "sk-platform") do
    Application.put_env(:fountain, provider, key)
  end

  describe "key_for/1 and enabled?/0" do
    test "off with nothing configured, and a blank value is still off" do
      refute PlatformInference.enabled?()
      assert PlatformInference.key_for("anthropic") == :none

      Application.put_env(:fountain, :platform_anthropic_api_key, "")
      refute PlatformInference.enabled?()
      assert PlatformInference.key_for("anthropic") == :none
    end

    test "a configured key comes back under the credential the tenant's own uses" do
      with_platform_key()

      assert PlatformInference.enabled?()
      assert PlatformInference.key_for("anthropic") == {:ok, :anthropic_api_key, "sk-platform"}
      assert PlatformInference.key_for("openai") == :none
      assert PlatformInference.configured_providers() == ["anthropic"]
    end

    test "a provider Fountain cannot export a credential for is never platform-served" do
      with_platform_key()
      assert PlatformInference.key_for("ollama") == :none
      assert PlatformInference.key_for(nil) == :none
    end
  end

  describe "InferenceCredentials.select/2" do
    test "with no platform key an account with nothing gets the refusal, not a key" do
      assert InferenceCredentials.select("anthropic/claude-opus-5", %{}) ==
               {:error, :no_credential}
    end

    test "the tenant's own credential wins over a configured platform key" do
      with_platform_key()
      own = %{anthropic_api_key: "sk-tenant"}

      assert {:ok, :own, ^own} = InferenceCredentials.select("anthropic/claude-opus-5", own)
    end

    test "an OAuth token is a credential for anthropic and wins too" do
      with_platform_key()
      own = %{claude_code_oauth_token: "oauth"}

      assert {:ok, :own, ^own} = InferenceCredentials.select("anthropic/claude-opus-5", own)
    end

    test "the platform key is merged in, leaving the tenant's other credentials alone" do
      with_platform_key()
      own = %{openai_api_key: "sk-tenant-openai"}

      assert {:ok, :platform, creds} = InferenceCredentials.select("anthropic/claude-opus-5", own)
      assert creds.anthropic_api_key == "sk-platform"
      assert creds.openai_api_key == "sk-tenant-openai"
    end

    test "a provider with no platform key configured is still refused" do
      with_platform_key()

      assert InferenceCredentials.select("openai/gpt-5.5", %{}) == {:error, :no_credential}
    end

    test "a provider that needs no credential is :own, whatever is configured" do
      with_platform_key()

      assert {:ok, :own, %{}} = InferenceCredentials.select("ollama/llama3", %{})
      assert {:ok, :own, %{}} = InferenceCredentials.select(nil, %{})
    end

    test "an empty-string credential is not a credential" do
      with_platform_key()

      assert {:ok, :platform, creds} =
               InferenceCredentials.select("anthropic/claude-opus-5", %{anthropic_api_key: ""})

      assert creds.anthropic_api_key == "sk-platform"
    end
  end

  describe "gate/2" do
    setup do
      %{user: insert_verified_user()}
    end

    test "with no platform key nothing is gated", %{user: user} do
      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
    end

    test "under the ceiling a platform account passes", %{user: user} do
      with_platform_key()
      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
    end

    test "over the ceiling a platform account is refused", %{user: user} do
      with_platform_key()
      Application.put_env(:fountain, :platform_inference_daily_cents, 10)
      burn_inference(user, 10)

      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") ==
               {:error, :platform_inference_unavailable}
    end

    test "a tenant with their own key is never touched by the ceiling", %{user: user} do
      with_platform_key()
      Application.put_env(:fountain, :platform_inference_daily_cents, 0)
      burn_inference(user, 500)

      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-mine")

      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
      # And the same account without the key would have been refused.
      assert PlatformInference.gate(insert_verified_user().id, "anthropic/claude-opus-5") ==
               {:error, :platform_inference_unavailable}
    end

    test "yesterday's spend does not count against today", %{user: user} do
      with_platform_key()
      Application.put_env(:fountain, :platform_inference_daily_cents, 10)
      entry = burn_inference(user, 500)

      entry
      |> Ecto.Changeset.change(
        inserted_at: DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert PlatformInference.gate(user.id, "anthropic/claude-opus-5") == :ok
    end
  end

  describe "check_ceiling/0" do
    test "a zero ceiling refuses rather than reading as unbounded" do
      Application.put_env(:fountain, :platform_inference_daily_cents, 0)

      assert PlatformInference.check_ceiling() ==
               {:error, :platform_inference_unavailable}
    end

    test "the default ceiling is $50" do
      Application.delete_env(:fountain, :platform_inference_daily_cents)
      assert PlatformInference.daily_ceiling_cents() == 5_000
    end
  end

  defp burn_inference(user, cents) do
    {:ok, entry} =
      Credits.debit(user.id, cents, "burn_inference",
        idempotency_key: "burn_inference:test:#{System.unique_integer([:positive])}",
        actor: "system:test"
      )

    entry
  end
end
