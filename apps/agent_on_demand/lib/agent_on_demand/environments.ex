defmodule AgentOnDemand.Environments do
  @moduledoc "Context for environments and their secrets."

  import Ecto.Query, only: [from: 2]

  alias AgentOnDemand.Environments.{Environment, Secret}
  alias AgentOnDemand.Repo

  # ── environments ──────────────────────────────────────────────────────────

  def list_environments(user_id) do
    Repo.all(
      from e in Environment,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  @doc "Returns the environment if it belongs to user_id, otherwise nil."
  def get_environment(id, user_id), do: Repo.get_by(Environment, id: id, user_id: user_id)

  @doc """
  Returns the environment. Raises Ecto.NoResultsError if not found or
  the environment does not belong to user_id (cross-tenant access → 404,
  not 403, to avoid leaking existence).
  """
  def get_environment!(id, user_id), do: Repo.get_by!(Environment, id: id, user_id: user_id)

  def create_environment(attrs, user_id) do
    %Environment{}
    |> Environment.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
  end

  def update_environment(%Environment{} = env, attrs, _user_id) do
    env
    |> Environment.changeset(attrs)
    |> Repo.update()
  end

  # user_id is accepted for call-site symmetry; ownership was enforced
  # by the get_environment!/2 that preceded this call.
  def delete_environment(%Environment{} = env, _user_id), do: Repo.delete(env)

  # ── secrets ───────────────────────────────────────────────────────────────

  def list_secrets(%Environment{id: env_id}) do
    Repo.all(from s in Secret, where: s.environment_id == ^env_id, order_by: [asc: s.key])
  end

  def get_secret(env_id, key) do
    Repo.get_by(Secret, environment_id: env_id, key: key)
  end

  def upsert_secret(%Environment{id: env_id}, %{"key" => key} = attrs) do
    case get_secret(env_id, key) do
      nil ->
        %Secret{}
        |> Secret.changeset(Map.put(attrs, "environment_id", env_id))
        |> Repo.insert()

      existing ->
        existing
        |> Secret.changeset(attrs)
        |> Repo.update()
    end
  end

  def delete_secret(%Secret{} = secret), do: Repo.delete(secret)

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` using the platform-level
  SECRETS_KEY. Used on code paths that haven't yet been migrated to
  per-tenant DEKs (e.g. environment preview in the admin UI).
  """
  def decrypted_env(%Environment{} = env) do
    env
    |> list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case Secret.decrypt(secret) do
        {:ok, plain} -> Map.put(acc, secret.key, plain)
        :error -> acc
      end
    end)
  end

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` using an explicit
  per-tenant DEK. Called by ConversationServer after it loads
  `Fountain.Crypto.load_tenant_key(user_id)` in `init/1`.
  """
  def decrypted_env(%Environment{} = env, dek) when is_binary(dek) do
    env
    |> list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case Secret.decrypt(secret, dek) do
        {:ok, plain} -> Map.put(acc, secret.key, plain)
        :error -> acc
      end
    end)
  end
end
