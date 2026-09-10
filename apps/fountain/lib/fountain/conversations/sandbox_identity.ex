defmodule Fountain.Conversations.SandboxIdentity do
  @moduledoc """
  Persist a sandbox's provider identity from an owned control-plane lookup.

  This is identity recording, not authorization for a subsequent provider write.
  Lifecycle operations still need durable intent and a coordinated incarnation
  check; a GET followed by a name-based DELETE is not atomic.
  """

  import Ecto.Query
  alias Fountain.Conversations.Sandbox
  alias Fountain.{Audit, Repo}
  alias Managoat.Sandbox.Handle

  @doc "Read control metadata, then bind the unchanged owned row; refuses an open transaction."
  def _unsafe_capture(%Sandbox{} = observed, %Handle{} = handle) do
    if Repo.in_transaction?(),
      do: {:error, :transaction_open},
      else: capture(observed, handle)
  end

  defp capture(observed, handle) do
    with true <- handle.name == observed.sprite_name,
         true <- is_atom(handle.provider),
         true <- Atom.to_string(handle.provider) == observed.provider,
         {:ok, %{raw: %{"name" => name, "id" => id}}} <- Managoat.Sandbox.get(handle),
         true <- name == observed.sprite_name do
      # Ownership: the caller supplied its owned sandbox; binding rechecks the row.
      _unsafe_bind(observed, id)
    else
      false -> {:error, :ownership_changed}
      {:error, _} = error -> error
      _ -> {:error, :provider_identity_missing}
    end
  end

  @doc """
  Bind trusted provider metadata once; never accept identity from worker output.
  Call outside a transaction so the best-effort audit follows the binding commit.
  """
  def _unsafe_bind(%Sandbox{} = observed, id) when is_binary(id) and byte_size(id) in 1..256 do
    if Repo.in_transaction?(), do: {:error, :transaction_open}, else: bind(observed, id)
  end

  def _unsafe_bind(%Sandbox{}, _), do: {:error, :provider_identity_missing}

  defp bind(observed, id) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(observed.id)])
        current = Repo.one(from s in Sandbox, where: s.id == ^observed.id, lock: "FOR UPDATE")
        if is_nil(current), do: Repo.rollback(:not_found)

        unless same_binding?(current, observed), do: Repo.rollback(:ownership_changed)
        if current.status in ["failed", "terminated"], do: Repo.rollback(:sandbox_retired)

        case current.provider_instance_id do
          nil ->
            changeset =
              current
              |> Ecto.Changeset.change(provider_instance_id: id)
              |> Ecto.Changeset.unique_constraint([:provider, :provider_instance_id])

            case Repo.update(changeset) do
              {:ok, bound} -> {bound, true}
              {:error, changeset} -> Repo.rollback(changeset)
            end

          ^id ->
            {current, false}

          _ ->
            Repo.rollback(:provider_identity_changed)
        end
      end)

    case result do
      {:ok, {bound, changed?}} ->
        if changed? do
          Audit.record(%{
            user_id: bound.user_id,
            action: "sandbox.provider_identity_bound",
            resource_type: "sandbox",
            resource_id: bound.id,
            actor: "system:sandbox_identity",
            metadata: %{"provider" => bound.provider}
          })
        end

        {:ok, bound}

      {:error, _} = error ->
        error
    end
  end

  defp same_binding?(current, observed) do
    current.user_id == observed.user_id and current.provider == observed.provider and
      current.sprite_name == observed.sprite_name
  end
end
