defmodule Fountain.Manifest do
  @moduledoc """
  Bulk apply for compiled IaC manifests (`fountain apply`).

  Takes the full list of resources the CLI compiled from a `fountain.yml`
  and reconciles them against the tenant's records in one pass:
  environments first, then vaults, then agents — the same fixed ordering
  `fountain apply` has always used, so an Agent doc can reference an
  Environment by name regardless of document order. Agent `environment`
  references resolve against environments in this manifest first, then
  against the tenant's existing environments.

  Application is best-effort per resource: a document that fails validation,
  that a context refuses, or that raises is reported in its own result entry
  and does not stop the rest of the manifest.
  """

  require Logger

  alias Fountain.{Agents, Crypto, Environments, Vaults}

  @unexpected "apply failed unexpectedly; see the server log"

  @kinds ~w(Environment Vault Agent)

  def kinds, do: @kinds

  # Ownership/identity fields are never taken from a manifest spec; secrets
  # are split out and written through the envelope-encryption path instead.
  @stripped_keys ~w(id user_id created_by secrets)

  @doc """
  Apply `resources` (maps with `"kind"`, `"name"`, and `"spec"`) for `user_id`.

  Returns `{:ok, results}` with one result map per resource in apply order
  (environments, vaults, agents, then any malformed entries). Each result
  holds `:kind`, `:name`, an `:action` of `:created` / `:updated` /
  `:unchanged` / `:error`, changeset-style `:errors` when the action is
  `:error`, a `:secrets` list with the per-key upsert outcome, and the
  reconciled record's `:id` (nil for errors and for kinds that carry no
  secrets). Secret values are never echoed back.

  `:unchanged` means the record already matched the document, so nothing was
  written to it. Inline `spec.secrets` are re-encrypted on every apply and
  keep reporting `:upserted` in `:secrets`, whatever the row's own verdict
  says: the stored ciphertext cannot be compared with the plaintext given.
  """
  def apply_manifest(user_id, resources, opts \\ [])
      when is_binary(user_id) and is_list(resources) do
    {valid, invalid} = Enum.split_with(resources, &valid_resource?/1)
    groups = Enum.group_by(valid, & &1["kind"])
    envs = Map.get(groups, "Environment", [])
    vaults = Map.get(groups, "Vault", [])
    agents = Map.get(groups, "Agent", [])

    dek = if Enum.any?(envs ++ vaults, &has_secrets?/1), do: load_dek!(user_id)

    {env_results, env_ids} =
      reconcile("Environment", envs, fn res -> apply_environment(user_id, res, dek, opts) end)

    {vault_results, _} =
      reconcile("Vault", vaults, fn res -> apply_vault(user_id, res, dek, opts) end)

    {agent_results, _} =
      reconcile("Agent", agents, fn res -> apply_agent(user_id, res, env_ids, opts) end)

    results =
      env_results ++
        vault_results ++
        agent_results ++
        Enum.map(invalid, &invalid_result/1)

    {:ok, results}
  end

  # One pass over one kind. Every `apply_*` returns `{result, id}`, so the
  # pass leaves behind the name -> id map the next pass resolves references
  # against.
  defp reconcile(kind, resources, fun) do
    Enum.map_reduce(resources, %{}, fn res, acc ->
      case guarded(kind, res["name"], fn -> fun.(res) end) do
        {result, nil} -> {result, acc}
        {result, id} -> {result, Map.put(acc, res["name"], id)}
      end
    end)
  end

  # Best-effort per resource means per resource. A raise or an exit in one
  # document's reconcile would abandon a call that has already committed the
  # documents above it, leaving the caller a 500 and no rows at all, against a
  # moduledoc promising best effort per resource. Reported as this document's
  # error instead, and logged, because a crash in a context is still a defect
  # worth a stacktrace.
  #
  # The row says only that the pass failed. The exception text goes to the log
  # above and no further: this module promises that secret values are never
  # echoed back, and the environment and vault passes hold plaintext inside
  # this rescue, where Elixir's own MatchError, CaseClauseError, BadMapError
  # and ArgumentError messages embed the value they choked on. A caller who
  # needs the detail has an operator who can read the log.
  defp guarded(kind, name, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "apply: #{kind} #{inspect(name)} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {result(kind, str(name), :error, %{"base" => [@unexpected]}, []), nil}
  catch
    thrown, reason ->
      Logger.error("apply: #{kind} #{inspect(name)} #{thrown}: #{inspect(reason)}")

      {result(kind, str(name), :error, %{"base" => [@unexpected]}, []), nil}
  end

  # Keeps the `via: apply` marker the ApplyController used to attach when it
  # audited these itself. It is the one thing distinguishing a secret written
  # by `fountain apply` from the same key written through a form, and worth
  # keeping now that the context emits the event (#593).
  defp secret_opts(opts) do
    Keyword.update(opts, :metadata, %{"via" => "apply"}, &Map.put(&1, "via", "apply"))
  end

  # ── per-kind reconciliation ───────────────────────────────────────────────

  defp apply_environment(user_id, %{"name" => name} = res, dek, opts) do
    with :ok <- validate_spec(res, Environments.Environment, ~w(secrets)) do
      {attrs, secrets} = split_spec(res, name)
      existing = Environments.get_environment_by_name(name, user_id)

      outcome =
        if existing,
          do: Environments.update_environment(existing, attrs, opts),
          else: Environments.create_environment(Map.put(attrs, "user_id", user_id), opts)

      case outcome do
        {:ok, env} ->
          secret_results =
            upsert_secrets(secrets, &Environments.upsert_secret(env, &1, dek, secret_opts(opts)))

          {result("Environment", name, verdict(existing, env), nil, secret_results, env.id),
           env.id}

        {:error, changeset} ->
          {result("Environment", name, :error, changeset_errors(changeset), []), nil}
      end
    else
      {:error, errors} -> {result("Environment", name, :error, errors, []), nil}
    end
  end

  defp apply_vault(user_id, %{"name" => name} = res, dek, opts) do
    with :ok <- validate_spec(res, Vaults.Vault, ~w(secrets)) do
      {attrs, secrets} = split_spec(res, name)
      existing = Vaults.get_vault_by_name(name, user_id)

      outcome =
        if existing,
          do: Vaults.update_vault(existing, attrs, opts),
          else: Vaults.create_vault(Map.put(attrs, "user_id", user_id), opts)

      case outcome do
        {:ok, vault} ->
          secret_results =
            upsert_secrets(secrets, &Vaults.upsert_secret(vault, &1, dek, secret_opts(opts)))

          {result("Vault", name, verdict(existing, vault), nil, secret_results, vault.id),
           vault.id}

        {:error, changeset} ->
          {result("Vault", name, :error, changeset_errors(changeset), []), nil}
      end
    else
      {:error, errors} -> {result("Vault", name, :error, errors, []), nil}
    end
  end

  defp apply_agent(user_id, %{"name" => name} = res, env_id_by_name, opts) do
    with :ok <- validate_spec(res, Agents.Agent, ~w(environment)) do
      {attrs, _secrets} = split_spec(res, name)
      {env_ref, attrs} = Map.pop(attrs, "environment")

      case resolve_environment_ref(user_id, env_ref, env_id_by_name) do
        {:ok, env_attrs} ->
          attrs = Map.merge(attrs, env_attrs)

          existing = Agents.get_agent_by_name(name, user_id)

          outcome =
            if existing,
              do: Agents.update_agent(existing, attrs, opts),
              else: Agents.create_agent(Map.put(attrs, "user_id", user_id), opts)

          case outcome do
            {:ok, agent} ->
              {result("Agent", name, verdict(existing, agent), nil, [], agent.id), agent.id}

            # Moving the agent's environment rebuilds its machine, which a
            # running turn blocks (#1084). Reported against the field that
            # caused it so `fountain apply` says what to do about it.
            {:error, :sandbox_mid_turn} ->
              errors = %{
                "environment" => [
                  "the agent is running a turn on its own machine; changing its " <>
                    "environment rebuilds that machine — retry once the turn ends"
                ]
              }

              {result("Agent", name, :error, errors, []), nil}

            {:error, cs} ->
              {result("Agent", name, :error, changeset_errors(cs), []), nil}
          end

        {:error, ref} ->
          errors = %{"environment" => ["environment not found: #{ref}"]}
          {result("Agent", name, :error, errors, []), nil}
      end
    else
      {:error, errors} -> {result("Agent", name, :error, errors, []), nil}
    end
  end

  # Resolve an agent's `environment: <name>` reference: environments applied
  # earlier in this manifest win, then the tenant's existing environments.
  defp resolve_environment_ref(_user_id, ref, _env_id_by_name) when ref in [nil, ""],
    do: {:ok, %{}}

  defp resolve_environment_ref(user_id, ref, env_id_by_name) when is_binary(ref) do
    case env_id_by_name[ref] || existing_env_id(user_id, ref) do
      nil -> {:error, ref}
      id -> {:ok, %{"environment_id" => id}}
    end
  end

  defp resolve_environment_ref(_user_id, ref, _env_id_by_name), do: {:error, inspect(ref)}

  defp existing_env_id(user_id, name) do
    case Environments.get_environment_by_name(name, user_id) do
      nil -> nil
      env -> env.id
    end
  end

  # ── secrets ───────────────────────────────────────────────────────────────

  defp upsert_secrets(secrets, upsert_fun) do
    secrets
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} ->
      case normalize_secret_value(value) do
        {:ok, plain} ->
          case upsert_fun.(%{"key" => key, "value" => plain}) do
            {:ok, _secret} -> %{key: key, action: :upserted, errors: nil}
            {:error, cs} -> %{key: key, action: :error, errors: changeset_errors(cs)}
          end

        :error ->
          %{key: key, action: :error, errors: %{"value" => ["must be a string"]}}
      end
    end)
  end

  defp normalize_secret_value(value) when is_binary(value), do: {:ok, value}

  defp normalize_secret_value(value) when is_number(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp normalize_secret_value(_value), do: :error

  defp has_secrets?(%{"spec" => %{"secrets" => secrets}}) when is_map(secrets),
    do: map_size(secrets) > 0

  defp has_secrets?(_res), do: false

  defp load_dek!(user_id) do
    {:ok, dek} = Crypto.load_tenant_key(user_id)
    dek
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp valid_resource?(%{"kind" => kind, "name" => name} = res)
       when kind in @kinds and is_binary(name) and name != "" do
    case Map.get(res, "spec") do
      nil -> true
      spec when is_map(spec) -> true
      _other -> false
    end
  end

  defp valid_resource?(_res), do: false

  # Use the changeset's cast fields, not every database field: timestamps,
  # virtual counts and other read-only state must not look configurable.
  defp validate_spec(res, schema, extra_keys) do
    allowed =
      Enum.map(schema.cast_fields(), &Atom.to_string/1) ++ extra_keys ++ ~w(id user_id created_by)

    unknown = Map.keys(res["spec"] || %{}) -- allowed

    case unknown do
      [] -> :ok
      keys -> {:error, Map.new(keys, &{&1, ["is not a supported spec key"]})}
    end
  end

  # The top-level resource name is authoritative — it is the upsert key, so
  # it overrides any `name` a spec happens to carry.
  defp split_spec(%{"spec" => spec}, name) when is_map(spec) do
    secrets =
      case Map.get(spec, "secrets") do
        m when is_map(m) -> m
        _other -> %{}
      end

    {spec |> Map.drop(@stripped_keys) |> Map.put("name", name), secrets}
  end

  defp split_spec(_res, name), do: {%{"name" => name}, %{}}

  # The third verdict. A record the manifest did not move reads `unchanged`,
  # so a second apply of the same file says plainly that it wrote nothing.
  # Compared over the schema's own columns with the timestamps left out: an
  # Ecto update with no changes moves neither.
  defp verdict(nil, _updated), do: :created

  defp verdict(%mod{} = before, %mod{} = updated) do
    fields = mod.__schema__(:fields) -- [:inserted_at, :updated_at]

    if Map.take(before, fields) == Map.take(updated, fields), do: :unchanged, else: :updated
  end

  # `id` is the reconciled record's id when there is one. It is not serialized
  # in the API response; callers use it to attribute the secret writes this
  # manifest performed to a concrete resource in the audit trail (#530).
  defp result(kind, name, action, errors, secrets, id \\ nil) do
    %{kind: kind, name: name, action: action, errors: errors, secrets: secrets, id: id}
  end

  defp invalid_result(res) do
    errors = %{
      "resource" => ["must have kind (Environment | Vault | Agent), name, and a map spec"]
    }

    result(str(res["kind"]), str(res["name"]), :error, errors, [])
  end

  defp str(value) when is_binary(value), do: value
  defp str(_value), do: ""

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
