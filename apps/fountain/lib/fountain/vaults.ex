defmodule Fountain.Vaults do
  @moduledoc """
  Context for vaults — free-floating bags of env-var overrides selected
  at conversation creation. Layered on top of an environment's baseline
  secrets at sprite spawn time; vault values win on key collision.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Audit
  alias Fountain.Repo
  alias Fountain.Vaults.{Vault, VaultSecret}

  # ── vaults ────────────────────────────────────────────────────────────────

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_vault(id), do: Repo.get(Vault, id)

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_vault!(id), do: Repo.get!(Vault, id)

  @doc "WARNING: lookup by name without owner check. Admin/internal use only."
  def _unsafe_get_vault_by_name(name), do: Repo.get_by(Vault, name: name)

  @doc "List vaults scoped to user."
  def list_vaults(user_id) when is_binary(user_id) do
    Repo.all(
      from v in Vault,
        where: v.user_id == ^user_id,
        order_by: [desc: v.inserted_at, desc: v.id]
    )
  end

  @doc """
  List vaults scoped to user, with `:secret_count` attached as a virtual
  field via a lightweight aggregation query.
  """
  def list_vaults_with_counts(user_id) when is_binary(user_id) do
    secret_counts_query =
      from s in VaultSecret,
        join: v in Vault,
        on: s.vault_id == v.id,
        where: v.user_id == ^user_id,
        group_by: s.vault_id,
        select: %{vault_id: s.vault_id, count: count(s.id)}

    vaults =
      Repo.all(
        from v in Vault,
          where: v.user_id == ^user_id,
          order_by: [desc: v.inserted_at, desc: v.id]
      )

    secret_map =
      secret_counts_query
      |> Repo.all()
      |> Map.new(&{&1.vault_id, &1.count})

    Enum.map(vaults, fn vault ->
      Map.put(vault, :secret_count, Map.get(secret_map, vault.id, 0))
    end)
  end

  @doc "Get vault scoped to user. Returns nil on wrong owner or missing id."
  def get_vault(id, user_id) when is_binary(user_id) do
    Repo.get_by(Vault, id: id, user_id: user_id)
  end

  @doc """
  Scoped fetch plus the `secret_count` the list read-model carries.
  """
  def get_vault_with_counts(id, user_id) when is_binary(user_id) do
    case get_vault(id, user_id) do
      nil ->
        nil

      vault ->
        count = Repo.aggregate(from(s in VaultSecret, where: s.vault_id == ^vault.id), :count)
        %{vault | secret_count: count}
    end
  end

  @doc "Get vault scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_vault!(id, user_id) when is_binary(user_id) do
    Repo.get_by!(Vault, id: id, user_id: user_id)
  end

  @doc "Get vault by name scoped to user. Returns nil when missing."
  def get_vault_by_name(name, user_id) when is_binary(name) and is_binary(user_id) do
    Repo.get_by(Vault, name: name, user_id: user_id)
  end

  @doc """
  Create a vault.

  `opts` carries the audit attribution — `:actor` and `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface. Recording here rather
  than at each caller is what makes the UI, the API and manifest apply all
  leave the same trail (#543).
  """
  def create_vault(attrs, opts \\ []) do
    %Vault{}
    |> Vault.changeset(attrs)
    |> Repo.insert()
    |> audited("vault.created", opts)
  end

  @doc "Update a vault. See `create_vault/2` for `opts`."
  def update_vault(%Vault{} = vault, attrs, opts \\ []) do
    changeset = Vault.changeset(vault, attrs)

    changeset
    |> Repo.update()
    |> audited("vault.updated", merge_metadata(opts, Audit.changed_fields(changeset)))
  end

  @doc """
  Delete a vault. See `create_vault/2` for `opts`.

  The secrets inside go with it by cascade, and the trail already carries a
  `vault.secret.write` for each one that was ever set — so a single
  `vault.deleted` row is enough to explain their disappearance.

  The homes built on it go first (#1084). `sandboxes.vault_id` is
  `ON DELETE SET NULL`, so leaving them is not a stray-orphan problem but two
  concrete ones: the row becomes the *no-vault* home for that identity, and
  the next launch that asks for no vault lands on a disk with this vault's
  secrets still materialised on it — or, when such a home already exists, the
  nilify collides with `sandboxes_home_identity_index` (`NULLS NOT DISTINCT`)
  and the delete fails with a constraint error the caller cannot act on.
  Torn down while `vault_id` still names them, for the same reason
  `delete_agent/2` tears homes down before the agent row goes.

  Refused with `:sandbox_mid_turn` while a conversation on one of those homes
  is running a turn.
  """
  def delete_vault(%Vault{} = vault, opts \\ []) do
    # Ownership: `vault` came from the caller's scoped fetch, and a home
    # carries the same `user_id` as the vault its identity names.
    homes = Fountain.Conversations._unsafe_homes_for_vault(vault.id)

    if Fountain.Conversations._unsafe_any_home_mid_turn?(homes) do
      {:error, :sandbox_mid_turn}
    else
      _ = Fountain.Conversations._unsafe_retire_orphaned_homes(homes, "vault_deleted", opts)
      vault |> Repo.delete() |> audited("vault.deleted", opts)
    end
  end

  # See the note in `Fountain.Agents.audited/3`: this runs outside any
  # enclosing transaction, because best-effort audit recording is only
  # best-effort outside one.
  defp audited({:ok, %Vault{} = vault} = ok, action, opts) do
    Audit.record_resource(action, "vault", vault, opts)
    ok
  end

  defp audited(other, _action, _opts), do: other

  defp merge_metadata(opts, extra) do
    Keyword.update(opts, :metadata, extra, &Map.merge(&1, extra))
  end

  # ── secrets ───────────────────────────────────────────────────────────────

  def _unsafe_list_secrets(%Vault{id: vault_id}) do
    Repo.all(from s in VaultSecret, where: s.vault_id == ^vault_id, order_by: [asc: s.key])
  end

  def _unsafe_get_secret(vault_id, key) do
    Repo.get_by(VaultSecret, vault_id: vault_id, key: key)
  end

  @doc """
  Insert or update a vault secret. The plaintext `attrs["value"]` is encrypted
  with the supplied per-tenant `dek` before persisting.
  """
  def upsert_secret(%Vault{} = vault, %{"key" => key} = attrs, dek, opts \\ [])
      when is_binary(dek) do
    case _unsafe_get_secret(vault.id, key) do
      nil ->
        %VaultSecret{}
        |> VaultSecret.changeset(Map.put(attrs, "vault_id", vault.id), dek)
        |> Repo.insert()

      existing ->
        existing
        |> VaultSecret.changeset(attrs, dek)
        |> Repo.update()
    end
    |> audited_secret(vault, key, "vault.secret.write", opts)
  end

  @doc """
  Delete a vault secret.

  Takes the owning vault as well as the secret — see
  `Fountain.Environments.delete_secret/3` for why.
  """
  def delete_secret(%Vault{} = vault, %VaultSecret{} = secret, opts \\ []) do
    secret
    |> Repo.delete()
    |> audited_secret(vault, secret.key, "vault.secret.delete", opts)
  end

  # See the note on `Fountain.Environments.audited_secret/5`: the vault is the
  # resource, the key is the whole payload, the value never appears.
  defp audited_secret({:ok, _} = ok, %Vault{} = vault, key, action, opts) do
    Audit.record(%{
      user_id: vault.user_id,
      action: action,
      resource_type: "vault_secret",
      resource_id: vault.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.merge(%{"key" => key}, Keyword.get(opts, :metadata, %{}))
    })

    ok
  end

  defp audited_secret(other, _vault, _key, _action, _opts), do: other

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` of all decrypted secrets
  in the given vault. Used when materializing env vars into a Sprite.
  Caller must supply the per-tenant `dek` (load via `Fountain.Crypto.load_tenant_key/1`).
  """
  def decrypted_env(%Vault{} = vault, dek) when is_binary(dek) do
    vault
    |> _unsafe_list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case VaultSecret.decrypt(secret, dek) do
        {:ok, plain} -> Map.put(acc, secret.key, plain)
        :error -> acc
      end
    end)
  end
end
