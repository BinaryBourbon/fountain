defmodule Fountain.Environments do
  @moduledoc "Context for environments and their secrets."

  import Ecto.Query, only: [from: 2]

  alias Fountain.Agents.Agent
  alias Fountain.Audit
  alias Fountain.Environments.{Environment, Secret}
  alias Fountain.Repo

  # ── environments ──────────────────────────────────────────────────────────

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_environment(id), do: Repo.get(Environment, id)

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_environment!(id), do: Repo.get!(Environment, id)

  @doc "List environments scoped to user."
  def list_environments(user_id) when is_binary(user_id) do
    Repo.all(
      from e in Environment,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  @doc """
  List environments scoped to user, with `:secret_count` and `:agent_count`
  attached as virtual fields via two lightweight aggregation queries.
  """
  def list_environments_with_counts(user_id) when is_binary(user_id) do
    secret_counts_query =
      from s in Secret,
        join: e in Environment,
        on: s.environment_id == e.id,
        where: e.user_id == ^user_id,
        group_by: s.environment_id,
        select: %{environment_id: s.environment_id, count: count(s.id)}

    agent_counts_query =
      from a in Agent,
        where: a.user_id == ^user_id,
        where: not is_nil(a.environment_id),
        group_by: a.environment_id,
        select: %{environment_id: a.environment_id, count: count(a.id)}

    envs =
      Repo.all(
        from e in Environment,
          where: e.user_id == ^user_id,
          order_by: [desc: e.inserted_at, desc: e.id]
      )

    secret_map =
      secret_counts_query
      |> Repo.all()
      |> Map.new(&{&1.environment_id, &1.count})

    agent_map =
      agent_counts_query
      |> Repo.all()
      |> Map.new(&{&1.environment_id, &1.count})

    Enum.map(envs, fn env ->
      env
      |> Map.put(:secret_count, Map.get(secret_map, env.id, 0))
      |> Map.put(:agent_count, Map.get(agent_map, env.id, 0))
    end)
  end

  @doc "Get environment scoped to user. Returns nil on wrong owner or missing id."
  def get_environment(id, user_id) when is_binary(user_id) do
    Repo.get_by(Environment, id: id, user_id: user_id)
  end

  @doc """
  Scoped fetch plus the counts the list read-model carries — how many secrets
  the environment holds and how many agents reference it. The second is the
  "is this safe to delete" answer, which callers otherwise N+1 client-side.
  """
  def get_environment_with_counts(id, user_id) when is_binary(user_id) do
    case get_environment(id, user_id) do
      nil ->
        nil

      env ->
        secret_count =
          Repo.aggregate(from(s in Secret, where: s.environment_id == ^env.id), :count)

        agent_count =
          Repo.aggregate(
            from(a in Agent, where: a.user_id == ^user_id and a.environment_id == ^env.id),
            :count
          )

        %{env | secret_count: secret_count, agent_count: agent_count}
    end
  end

  @doc "Get environment scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_environment!(id, user_id) when is_binary(user_id) do
    Repo.get_by!(Environment, id: id, user_id: user_id)
  end

  @doc "Get environment by name scoped to user. Returns nil when missing."
  def get_environment_by_name(name, user_id) when is_binary(name) and is_binary(user_id) do
    Repo.get_by(Environment, name: name, user_id: user_id)
  end

  @doc """
  Create an environment.

  `opts` carries the audit attribution — `:actor` and `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface. Recording here rather
  than at each caller is what makes the UI, the API, the onboarding wizard and
  manifest apply all leave the same trail (#543).
  """
  def create_environment(attrs, opts \\ []) do
    %Environment{}
    |> Environment.changeset(attrs)
    |> Repo.insert()
    |> audited("environment.created", opts)
  end

  @doc """
  Update an environment. See `create_environment/2` for `opts`.

  The checkpoint writers in `ConversationServer` and `Provisioning` come
  through here too, with a `system:` actor. Those rows are worth keeping: a
  checkpoint pointer moving under the tenant is exactly what someone
  debugging a cold provision needs to see, and the changed-field list says
  plainly that nothing the tenant configured was touched.
  """
  def update_environment(%Environment{} = env, attrs, opts \\ []) do
    changeset = Environment.changeset(env, attrs)

    changeset
    |> Repo.update()
    |> audited("environment.updated", merge_metadata(opts, Audit.changed_fields(changeset)))
  end

  @doc """
  Delete an environment. See `create_environment/2` for `opts`.

  The homes built on it go first (#1084), for the reason spelled out in
  `Fountain.Vaults.delete_vault/2`: `sandboxes.environment_id` is
  `ON DELETE SET NULL`, so a home left behind either becomes the *no
  environment* home for its identity — next launch lands on a disk holding the
  deleted environment's secrets — or collides with
  `sandboxes_home_identity_index` and fails the delete outright.

  Refused with `:sandbox_mid_turn` while a conversation on one of those homes
  is running a turn.
  """
  def delete_environment(%Environment{} = env, opts \\ []) do
    # Ownership: `env` came from the caller's scoped fetch, and a home carries
    # the same `user_id` as the environment its identity names.
    homes = Fountain.Conversations._unsafe_homes_for_environment(env.id)

    if Fountain.Conversations._unsafe_any_home_mid_turn?(homes) do
      {:error, :sandbox_mid_turn}
    else
      _ = Fountain.Conversations._unsafe_retire_orphaned_homes(homes, "environment_deleted", opts)
      env |> Repo.delete() |> audited("environment.deleted", opts)
    end
  end

  # See the note in `Fountain.Agents.audited/3`: this runs outside any
  # enclosing transaction, because best-effort audit recording is only
  # best-effort outside one.
  defp audited({:ok, %Environment{} = env} = ok, action, opts) do
    Audit.record_resource(action, "environment", env, opts)
    ok
  end

  defp audited(other, _action, _opts), do: other

  defp merge_metadata(opts, extra) do
    Keyword.update(opts, :metadata, extra, &Map.merge(&1, extra))
  end

  # ── secrets ───────────────────────────────────────────────────────────────

  def _unsafe_list_secrets(%Environment{id: env_id}) do
    Repo.all(from s in Secret, where: s.environment_id == ^env_id, order_by: [asc: s.key])
  end

  def _unsafe_get_secret(env_id, key) do
    Repo.get_by(Secret, environment_id: env_id, key: key)
  end

  @doc """
  Insert or update an environment secret. The plaintext `attrs["value"]` is
  encrypted with the supplied per-tenant `dek` before persisting.

  Audited as `environment.secret.write`. Recorded here rather than by each
  caller: five surfaces wrote this same event independently — both LiveView
  forms, both API controllers, and `fountain apply` — and a sixth would have
  been one forgotten call from silence (#593). The key is recorded, never the
  value; that is the whole point of a write-only secret.
  """
  def upsert_secret(%Environment{} = env, %{"key" => key} = attrs, dek, opts \\ [])
      when is_binary(dek) do
    case _unsafe_get_secret(env.id, key) do
      nil ->
        %Secret{}
        |> Secret.changeset(Map.put(attrs, "environment_id", env.id), dek)
        |> Repo.insert()

      existing ->
        existing
        |> Secret.changeset(attrs, dek)
        |> Repo.update()
    end
    |> audited_secret(env, key, "environment.secret.write", opts)
  end

  @doc """
  Delete an environment secret.

  Takes the owning environment as well as the secret: `secrets` carries no
  `user_id`, so without it the audit event could not be attributed without a
  second query — and every call site already has the environment in hand.
  """
  def delete_secret(%Environment{} = env, %Secret{} = secret, opts \\ []) do
    secret
    |> Repo.delete()
    |> audited_secret(env, secret.key, "environment.secret.delete", opts)
  end

  # `resource_id` is the environment, not the secret row: a deleted secret's id
  # points at nothing, and "which environment" is the question a reader of the
  # trail is actually asking. Matches the shape the five call sites emitted
  # before this moved, so existing trails stay readable.
  defp audited_secret({:ok, _} = ok, %Environment{} = env, key, action, opts) do
    Audit.record(%{
      user_id: env.user_id,
      action: action,
      resource_type: "secret",
      resource_id: env.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.merge(%{"key" => key}, Keyword.get(opts, :metadata, %{}))
    })

    ok
  end

  defp audited_secret(other, _env, _key, _action, _opts), do: other

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` of all decrypted secrets
  attached to the given environment. Caller must supply the per-tenant `dek`
  (load via `Fountain.Crypto.load_tenant_key/1`).
  """
  def decrypted_env(%Environment{} = env, dek) when is_binary(dek) do
    env
    |> _unsafe_list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case Secret.decrypt(secret, dek) do
        {:ok, plain} -> Map.put(acc, secret.key, plain)
        :error -> acc
      end
    end)
  end
end
