defmodule Fountain.InferenceCredentials do
  @moduledoc """
  Context for per-user inference provider credentials.

  Tenants bring their own inference tokens (ADR 0008). This context handles
  encryption (using the per-tenant DEK from `Fountain.Crypto`) and decryption
  at the boundaries — `ConversationServer` decrypts at conversation start;
  the Settings LiveView encrypts on save.

  Plaintext values are never stored. The `decrypted_for_user/2` function
  returns a map with only those providers the user has set; missing
  providers are absent from the map (not set to `nil`).
  """

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials.Credential
  alias Fountain.Repo

  @providers Credential.providers()

  @doc """
  Fetch the credentials row for a user, or `nil` if absent.

  Returns the raw schema struct (with ciphertext blobs). Use
  `decrypted_for_user/2` to get plaintext values.
  """
  @spec get_for_user(binary()) :: Credential.t() | nil
  def get_for_user(user_id) when is_binary(user_id) do
    Repo.one(from c in Credential, where: c.user_id == ^user_id)
  end

  @doc """
  Returns a map `%{provider => plaintext}` of every credential the user has
  set, decrypted with the supplied tenant DEK. Missing providers are absent
  from the map.

  Returns `{:ok, map}` or `{:error, :decrypt_failed}` if any ciphertext fails
  to decrypt (likely a wrong DEK — should be impossible in normal operation).
  """
  @spec decrypted_for_user(binary(), binary()) ::
          {:ok, %{atom() => String.t()}} | {:error, :decrypt_failed}
  def decrypted_for_user(user_id, dek) when is_binary(user_id) and is_binary(dek) do
    case get_for_user(user_id) do
      nil ->
        {:ok, %{}}

      %Credential{} = cred ->
        Enum.reduce_while(@providers, {:ok, %{}}, fn provider, {:ok, acc} ->
          ct_field = ciphertext_field(provider)
          ct = Map.fetch!(cred, ct_field)

          case decrypt_field(ct, dek) do
            :empty -> {:cont, {:ok, acc}}
            {:ok, plain} -> {:cont, {:ok, Map.put(acc, provider, plain)}}
            :error -> {:halt, {:error, :decrypt_failed}}
          end
        end)
    end
  end

  @doc """
  Set or clear a single provider's credential for a user.

  - `value` is a plaintext string (will be encrypted with `dek`).
  - To clear, pass `nil` or an empty string.

  Audited as `inference_credential.write` or `.delete`. These are BYO
  inference keys — secret material on par with environment and vault secrets,
  which have audited since #530. The settings LiveView and the API controller
  each recorded their own event, and the onboarding wizard, saving the same
  credential through the same function, recorded nothing (#546). Recording
  here removes the third caller's gap and the chance of a fourth.

  `opts` carries `:actor` / `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface.

  Returns `{:ok, credential}` (the updated row) or `{:error, changeset}`.
  """
  @spec put_credential(binary(), binary(), atom(), String.t() | nil, keyword()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def put_credential(user_id, dek, provider, value, opts \\ [])
      when is_binary(user_id) and is_binary(dek) and provider in @providers do
    ct_field = ciphertext_field(provider)

    ciphertext =
      case value do
        nil -> nil
        "" -> nil
        plain when is_binary(plain) -> Crypto.encrypt(plain, dek)
      end

    existing = get_for_user(user_id) || %Credential{user_id: user_id}

    attrs = %{user_id: user_id} |> Map.put(ct_field, ciphertext)

    existing
    |> Credential.changeset(attrs)
    |> Repo.insert_or_update()
    |> audited(user_id, provider, ciphertext, opts)
  end

  # The provider name is the whole payload. The credential must never reach a
  # second table — the same rule the secret-write events follow, and the
  # reason those record a key and not a value.
  defp audited({:ok, _cred} = ok, user_id, provider, ciphertext, opts) do
    action =
      if is_nil(ciphertext), do: "inference_credential.delete", else: "inference_credential.write"

    Audit.record(%{
      user_id: user_id,
      action: action,
      resource_type: "inference_credential",
      resource_id: Atom.to_string(provider),
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"provider" => Atom.to_string(provider)}
    })

    ok
  end

  defp audited(other, _user_id, _provider, _ciphertext, _opts), do: other

  @doc """
  Returns `true` if the user has at least one provider set.

  Used by the onboarding wizard to gate the next step, and by the
  conversation-start flow to give a clearer error than "auth failed
  in the sprite."
  """
  @spec has_any_credential?(binary()) :: boolean()
  def has_any_credential?(user_id) when is_binary(user_id) do
    case get_for_user(user_id) do
      nil ->
        false

      %Credential{} = cred ->
        Enum.any?(@providers, fn p ->
          ct = Map.fetch!(cred, ciphertext_field(p))
          is_binary(ct) and byte_size(ct) > 0
        end)
    end
  end

  @doc """
  The credentials that let a model's provider run: a model `provider/id`
  names a provider; any one of these credentials serves it. Unknown
  providers (a local model, a gateway) need none — Fountain cannot know.

      iex> credentials_for_provider("anthropic")
      [:anthropic_api_key, :claude_code_oauth_token]
  """
  @spec credentials_for_provider(String.t() | nil) :: [atom()]
  def credentials_for_provider("anthropic"), do: [:anthropic_api_key, :claude_code_oauth_token]
  def credentials_for_provider("openai"), do: [:openai_api_key]
  def credentials_for_provider("google"), do: [:gemini_api_key]
  def credentials_for_provider(_), do: []

  @doc """
  What a model would be missing on this account: `nil` when one of the
  credentials its provider accepts is set (or the provider needs none),
  else `{provider, credentials}` — the provider's name and the credentials
  that would do. The onboarding wizard asks only for Anthropic; this is how
  the agent form and the API ask for the rest the first time a model needs
  them, rather than failing inside the sandbox.
  """
  @spec missing_for_model(binary(), String.t() | nil) :: nil | {String.t(), [atom()]}
  def missing_for_model(user_id, model) when is_binary(user_id) do
    provider = Fountain.Runtimes.Model.provider(model)

    case credentials_for_provider(provider) do
      [] ->
        nil

      accepted ->
        status = status_for_user(user_id)
        if Enum.any?(accepted, &Map.get(status, &1, false)), do: nil, else: {provider, accepted}
    end
  end

  @doc """
  Returns a map `%{provider => boolean}` of which providers the user has set.
  Cheap — does not decrypt; just checks for non-nil ciphertext.
  """
  @spec status_for_user(binary()) :: %{atom() => boolean()}
  def status_for_user(user_id) when is_binary(user_id) do
    case get_for_user(user_id) do
      nil ->
        Map.new(@providers, &{&1, false})

      %Credential{} = cred ->
        Map.new(@providers, fn p ->
          ct = Map.fetch!(cred, ciphertext_field(p))
          {p, is_binary(ct) and byte_size(ct) > 0}
        end)
    end
  end

  ## Private

  defp ciphertext_field(:anthropic_api_key), do: :anthropic_api_key_ciphertext
  defp ciphertext_field(:claude_code_oauth_token), do: :claude_code_oauth_token_ciphertext
  defp ciphertext_field(:openai_api_key), do: :openai_api_key_ciphertext
  defp ciphertext_field(:gemini_api_key), do: :gemini_api_key_ciphertext

  defp decrypt_field(nil, _dek), do: :empty

  defp decrypt_field(ct, dek) when is_binary(ct) do
    case Crypto.decrypt(ct, dek) do
      {:ok, plain} -> {:ok, plain}
      :error -> :error
    end
  end
end
