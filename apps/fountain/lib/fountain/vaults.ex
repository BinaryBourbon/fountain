defmodule Fountain.Vaults do
  @moduledoc """
  Context for vaults — free-floating bags of env-var overrides selected
  at conversation creation. Layered on top of an environment's baseline
  secrets at sprite spawn time; vault values win on key collision.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Repo
  alias Fountain.Vaults.{Vault, VaultSecret}

  # ── vaults ────────────────────────────────────────────────────────────────

  def list_vaults do
    Repo.all(from v in Vault, order_by: [desc: v.inserted_at, desc: v.id])
  end

  def get_vault(id), do: Repo.get(Vault, id)
  def get_vault!(id), do: Repo.get!(Vault, id)
  def get_vault_by_name(name), do: Repo.get_by(Vault, name: name)

  @doc "List vaults scoped to user."
  def list_vaults(user_id) when is_binary(user_id) do
    Repo.all(from v in Vault, where: v.user_id == ^user_id, order_by: [desc: v.inserted_at, desc: v.id])
  end

  @doc "Get vault scoped to user. Returns nil on wrong owner or missing id."
  def get_vault(id, user_id) when is_binary(user_id) do
    Repo.get_by(Vault, id: id, user_id: user_id)
  end

  @doc "Get vault scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_vault!(id, user_id) when is_binary(user_id) do
    Repo.get_by!(Vault, id: id, user_id: user_id)
  end

  def create_vault(attrs) do
    %Vault{}
    |> Vault.changeset(attrs)
    |> Repo.insert()
  end

  def update_vault(%Vault{} = vault, attrs) do
    vault
    |> Vault.changeset(attrs)
    |> Repo.update()
  end

  def delete_vault(%Vault{} = vault), do: Repo.delete(vault)

  # ── secrets ───────────────────────────────────────────────────────────────

  def list_secrets(%Vault{id: vault_id}) do
    Repo.all(from s in VaultSecret, where: s.vault_id == ^vault_id, order_by: [asc: s.key])
  end

  def get_secret(vault_id, key) do
    Repo.get_by(VaultSecret, vault_id: vault_id, key: key)
  end

  @doc """
  Insert or update a vault secret. The plaintext `attrs["value"]` is encrypted
  with the supplied per-tenant `dek` before persisting.
  """
  def upsert_secret(%Vault{id: vault_id}, %{"key" => key} = attrs, dek) when is_binary(dek) do
    case get_secret(vault_id, key) do
      nil ->
        %VaultSecret{}
        |> VaultSecret.changeset(Map.put(attrs, "vault_id", vault_id), dek)
        |> Repo.insert()

      existing ->
        existing
        |> VaultSecret.changeset(attrs, dek)
        |> Repo.update()
    end
  end

  def delete_secret(%VaultSecret{} = secret), do: Repo.delete(secret)

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` of all decrypted secrets
  in the given vault. Used when materializing env vars into a Sprite.
  Caller must supply the per-tenant `dek` (load via `Fountain.Crypto.load_tenant_key/1`).
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
