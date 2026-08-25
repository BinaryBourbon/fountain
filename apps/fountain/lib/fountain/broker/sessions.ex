defmodule Fountain.Broker.Sessions do
  @moduledoc """
  The broker's session store (ADR 0019, native broker).

  `Fountain.Broker.prepare/3` mints a session here for one conversation: a
  random token, the credentials the proxy may attach (ciphertext under the
  tenant's DEK, exactly as the environment and vault rows hold them), and
  the services that say which host gets which credential in which header.
  `Fountain.Broker.Proxy` resolves a token back to that binding on every
  new client connection, on whichever replica the ingress chose.

  A session is not tenant-editable state and is not audited: it is
  provisioning machinery, created and deleted with the sandbox it serves,
  and the audit trail records the conversation's lifecycle instead.
  """

  import Ecto.Query

  alias Fountain.Broker.Session
  alias Fountain.Crypto
  alias Fountain.Repo

  @aad "fountain.broker.credentials"

  @typedoc "What the proxy needs to serve one sandbox connection."
  @type binding :: %{
          conversation_id: String.t(),
          user_id: String.t(),
          vault: String.t(),
          credentials: %{String.t() => String.t()},
          services: [map()],
          unmatched_host_policy: String.t()
        }

  @doc """
  Mint a session. Returns the plaintext token exactly once; only its hash
  is stored. Expired sessions are swept on the way.
  """
  @spec create(%{
          conversation_id: String.t(),
          user_id: String.t(),
          vault: String.t(),
          credentials: %{String.t() => String.t()},
          services: [map()],
          unmatched_host_policy: String.t(),
          ttl_seconds: pos_integer()
        }) ::
          {:ok, %{token: String.t(), vault: String.t(), expires_at: DateTime.t()}}
          | {:error, term()}
  def create(%{conversation_id: conv_id, user_id: user_id} = attrs) do
    sweep_expired()

    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      token = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      expires_at = DateTime.add(DateTime.utc_now(), attrs.ttl_seconds, :second)

      changeset =
        Session.changeset(%Session{}, %{
          token_hash: hash(token),
          vault: attrs.vault,
          conversation_id: conv_id,
          user_id: user_id,
          credentials_ciphertext: Crypto.encrypt(Jason.encode!(attrs.credentials), dek, @aad),
          services: attrs.services,
          unmatched_host_policy: Map.get(attrs, :unmatched_host_policy, "passthrough"),
          expires_at: expires_at
        })

      case Repo.insert(changeset) do
        {:ok, _} -> {:ok, %{token: token, vault: attrs.vault, expires_at: expires_at}}
        {:error, changeset} -> {:error, {:broker, :session, changeset}}
      end
    end
  end

  @doc """
  Resolve a token to its binding. The vault in the proxy URL must be the one
  the token was minted for (ADR 0019 §11: the binding is on the token, and a
  token that honoured a different vault name would be a cross-tenant read).
  """
  @spec lookup(String.t(), String.t()) ::
          {:ok, binding()} | {:error, :unknown | :expired | :vault_mismatch | :undecryptable}
  def lookup(token, vault) when is_binary(token) and is_binary(vault) do
    case Repo.get_by(Session, token_hash: hash(token)) do
      nil ->
        {:error, :unknown}

      %Session{vault: v} when v != vault ->
        {:error, :vault_mismatch}

      %Session{} = session ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :lt,
          do: {:error, :expired},
          else: decrypt(session)
    end
  end

  @doc "Delete every session of a conversation. Its tokens stop working at once."
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id) do
    Repo.delete_all(from(s in Session, where: s.conversation_id == ^conversation_id))
    :ok
  end

  @doc "Delete sessions past their end."
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    now = DateTime.utc_now()
    {n, _} = Repo.delete_all(from(s in Session, where: s.expires_at < ^now))
    n
  end

  defp decrypt(%Session{} = s) do
    with {:ok, dek} <- Crypto.load_tenant_key(s.user_id),
         {:ok, json} <- Crypto.decrypt(s.credentials_ciphertext, dek, @aad),
         {:ok, credentials} <- Jason.decode(json) do
      {:ok,
       %{
         conversation_id: s.conversation_id,
         user_id: s.user_id,
         vault: s.vault,
         credentials: credentials,
         services: s.services,
         unmatched_host_policy: s.unmatched_host_policy
       }}
    else
      _ -> {:error, :undecryptable}
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
