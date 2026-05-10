defmodule AgentOnDemand.Vaults do
  @moduledoc """
  Context for vaults — free-floating bags of env-var overrides selected
  at conversation creation. Layered on top of an environment's baseline
  secrets at sprite spawn time; vault values win on key collision.
  """

  import Ecto.Query, only: [from: 2]

  alias AgentOnDemand.Repo
  alias AgentOnDemand.Vaults.{Vault, VaultSecret}

  # ── vaults ────────────────────────────────────────────────────────────────

  def list_vaults(user_id) do
    Repo.all(
      from v in Vault,
        where: v.user_id == ^user_id,
        order_by: [desc: v.inserted_at, desc: v.id]
    )
  end

  @doc "Returns the vault if it belongs to user_id, otherwise nil."
  def get_vault(id, user_id), do: Repo.get_by(Vault, id: id, user_id: user_id)

  @doc """
  Returns the vault. Raises Ecto.NoResultsError if not found or
  the vault does not belong to user_id (cross-tenant access → 404).
  """
  def get_vault!(id, user_id), do: Repo.get_by!(Vault, id: id, user_id: user_id)

  def get_vault_by_name(name, user_id), do: Repo.get_by(Vault, name: name, user_id: user_id)

  def create_vault(attrs, user_id) do
    %Vault{}
    |> Vault.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
  end

  def update_vault(%Vault{} = vault, attrs, _user_id) do
    vault
    |> Vault.changeset(attrs)
    |> Repo.update()
  end

  # user_id accepted for call-site symmetry; ownership enforced by prior fetch.
  def delete_vault(%Vault{} = vault, _user_id), do: Repo.delete(vault)

  # ── vault secrets ─────────────────────────────────────────────────────────

  @doc """
  Lists secrets for a vault, verifying the vault belongs to user_id.
  Raises Ecto.NoResultsError on cross-tenant access.
  """
  def list_vault_secrets(vault_id, user_id) do
    # Ownership check: raises if wrong owner.
    vault = get_vault!(vault_id, user_id)
    list_secrets(vault)
  end

  def list_secrets(%Vault{id: vault_id}) do
    Repo.all(from s in VaultSecret, where: s.vault_id == ^vault_id, order_by: [asc: s.key])
  end

  def get_secret(vault_id, key) do
    Repo.get_by(VaultSecret, vault_id: vault_id, key: key)
  end

  def upsert_secret(%Vault{id: vault_id}, %{"key" => key} = attrs) do
    case get_secret(vault_id, key) do
      nil ->
        %VaultSecret{}
        |> VaultSecret.changeset(Map.put(attrs, "vault_id", vault_id))
        |> Repo.insert()

      existing ->
        existing
        |> VaultSecret.changeset(attrs)
        |> Repo.update()
    end
  end

  def delete_secret(%VaultSecret{} = secret), do: Repo.delete(secret)

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` using the platform-level
  SECRETS_KEY (legacy / pre-tenant-DEK path).
  """
  def decrypted_env(%Vault{} = vault) do
    vault
    |> list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case VaultSecret.decrypt(secret) do
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
  def decrypted_env(%Vault{} = vault, dek) when is_binary(dek) do
    vault
    |> list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case VaultSecret.decrypt(secret, dek) do
        {:ok, plain} -> Map.put(acc, secret.key, plain)
        :error -> acc
      end
    end)
  end
end
