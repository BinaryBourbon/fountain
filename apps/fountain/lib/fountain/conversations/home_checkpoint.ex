defmodule Fountain.Conversations.HomeCheckpoint do
  @moduledoc """
  Checkpoint a persistent home when it parks (ADR 0023, #1073).

  A home's disk is the agent's memory across every conversation on it, so
  the moment it goes quiet is the moment its state is worth keeping. Where
  the provider advertises `:checkpoint`, both park paths — the
  `ConversationServer`'s idle and ceiling reclaim, and the reaper's park of a
  home with no live server — call `on_park/1` before flipping the row to
  `suspended`. The checkpoint id and time land in `sandboxes.provider_meta`
  (`checkpoint_id`, `checkpoint_at`) and a `checkpoint` stage is written to
  every live conversation on the machine, so each transcript shows it.

  What a checkpoint can restore, honestly: on Sprites a checkpoint is scoped
  to the sprite that created it (#654) and the SDK has no "create a sprite
  from a checkpoint", so it rolls *this* machine back and cannot rebuild a
  machine that is gone. The `{:machine_gone, …}` re-provision path therefore
  does not restore from it; a reset that rolls a home back to its last park
  is the path it is for. Ephemeral sandboxes are never checkpointed here —
  their disk dies with the conversation.

  Best-effort by construction: a failed checkpoint is logged and recorded as
  a failed stage, and the park goes ahead — an unparked machine keeps billing.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Retry

  require Logger

  @doc """
  Checkpoint `sandbox` if it is a home on a provider that can. Returns the
  checkpoint id, `:skipped` when there is nothing to do, or the error after
  it has been recorded.
  """
  @spec on_park(Sandbox.t()) :: {:ok, String.t()} | :skipped | {:error, term()}
  def on_park(%Sandbox{mode: "persistent", sprite_name: name} = sandbox) when is_binary(name) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    if Fountain.Sandbox.supports?(provider, :checkpoint) do
      create(sandbox, Fountain.Sandbox.build_handle(provider, name))
    else
      :skipped
    end
  end

  def on_park(_sandbox), do: :skipped

  @doc "The checkpoint recorded on `sandbox`, as `%{id, at}`, or nil."
  @spec recorded(Sandbox.t()) :: %{id: String.t(), at: String.t()} | nil
  def recorded(%Sandbox{provider_meta: %{"checkpoint_id" => id} = meta}) when is_binary(id) do
    %{id: id, at: meta["checkpoint_at"]}
  end

  def recorded(_sandbox), do: nil

  defp create(sandbox, handle) do
    comment = "home park #{sandbox.id}"

    result =
      Fountain.Telemetry.span([:checkpoint, :create], %{sandbox_id: sandbox.id}, fn ->
        # Retried: a duplicate checkpoint from a lost-response retry costs
        # storage, a missing one costs the state the park was meant to keep.
        case Retry.with_backoff(
               fn -> Fountain.Sandbox.create_checkpoint(handle, comment: comment) end,
               label: "home checkpoint"
             ) do
          {:ok, id} -> {{:ok, id}, %{outcome: :ok, checkpoint_id: id}}
          {:error, reason} -> {{:error, reason}, %{outcome: :error, reason: inspect(reason)}}
        end
      end)

    case result do
      {:ok, id} ->
        record(sandbox, id)
        {:ok, id}

      {:error, reason} ->
        Logger.warning(
          "home checkpoint failed for sandbox #{sandbox.id} (#{sandbox.sprite_name}): " <>
            "#{inspect(reason)}; parking without one"
        )

        publish(sandbox, "failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp record(sandbox, id) do
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    meta =
      Map.merge(sandbox.provider_meta || %{}, %{"checkpoint_id" => id, "checkpoint_at" => at})

    {:ok, _} = Conversations.update_sandbox(sandbox, %{provider_meta: meta})

    Logger.info("home checkpoint #{id} for sandbox #{sandbox.id} (#{sandbox.sprite_name})")
    publish(sandbox, "done", %{checkpoint_id: id})
  end

  # One stage per live conversation on the machine: the checkpoint is the
  # machine's, but transcripts are per conversation.
  # ownership: a system path — the caller is the ConversationServer or the
  # reaper acting on a sandbox row it already holds, never a tenant request.
  defp publish(sandbox, state, meta) do
    sandbox.id
    |> Conversations._unsafe_list_holder_ids()
    |> Enum.each(&Conversations.publish_stage(&1, "checkpoint", state, meta))
  end
end
