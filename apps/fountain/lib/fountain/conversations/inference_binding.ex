defmodule Fountain.Conversations.InferenceBinding do
  @moduledoc """
  Durable admission for the shared Codex auth location.

  Every preparing or resumable conversation reserves its resolved identity and
  revision. The sandbox row serializes contenders before any auth-file write.
  Legacy peers without a binding are incompatible. The machine retains its
  auth binding through conversation termination and deletion: a detached runtime
  may survive its actor, so only a new sandbox can change that binding.
  """
  import Ecto.Query
  alias Fountain.{InferenceCredentials, Repo}
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.InferenceCredentials.Source

  def reserve(conv, %Source{} = source) do
    InferenceCredentials.with_source_lock(conv.user_id, fn ->
      with :ok <- InferenceCredentials.validate_source(conv.user_id, source),
           :ok <- Fountain.PlatformInference.gate_source(source),
           :ok <- compatible_machine(conv, source) do
        case conv
             |> Ecto.Changeset.change(inference_source: Source.dump(source))
             |> Repo.update() do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp compatible_machine(%{runtime: runtime}, _) when runtime != "codex", do: :ok

  defp compatible_machine(conv, source) do
    sandbox =
      Repo.one(
        from s in Sandbox,
          where: s.id == ^conv.sandbox_id and s.user_id == ^conv.user_id,
          lock: "FOR NO KEY UPDATE"
      )

    if sandbox do
      peers =
        Repo.all(
          from c in Conversation,
            where: c.sandbox_id == ^sandbox.id and c.id != ^conv.id and c.runtime == "codex",
            select: c.inference_source
        )

      stored = sandbox.codex_inference_source

      fresh? = sandbox.status in ["pending", "starting"]

      if ((is_nil(stored) and fresh?) or compatible?(stored, Source.dump(source))) and
           Enum.all?(peers, &compatible?(&1, Source.dump(source))) do
        sandbox
        |> Ecto.Changeset.change(codex_inference_source: Source.dump(source))
        |> Repo.update!()

        :ok
      else
        {:error, :codex_inference_conflict}
      end
    else
      {:error, :sandbox_not_found}
    end
  end

  defp compatible?(nil, _), do: false

  defp compatible?(left, right),
    do: Map.take(left, ~w(kind identity revision)) == Map.take(right, ~w(kind identity revision))
end
