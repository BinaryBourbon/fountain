defmodule Fountain.Conversations.Checkpoints do
  @moduledoc """
  An environment's disk checkpoint: the warm start that restores one onto a
  freshly created machine, and the best-effort snapshot taken after a machine
  finishes provisioning (#1369).

  `Fountain.Conversations.Provisioning` owns the two sandbox calls
  (`restore_checkpoint/2` and `create_checkpoint/2`); what lives here is when
  to make them, what a failed restore does to the stale id, and the flag that
  keeps creation off.
  """

  require Logger

  alias Fountain.Conversations.{Output, Provisioning}
  alias Fountain.Environments.Environment

  @doc """
  Restore this environment's checkpoint onto a freshly created machine, or
  `:cold` when there is nothing to restore (#1369).

  A failed restore clears the stale `checkpoint_id` rather than retrying it on
  every later conversation, and provisions cold.
  """
  @spec attempt_warm_start(Managoat.Sandbox.Handle.t(), map() | nil, String.t()) ::
          :warm_started | :cold
  def attempt_warm_start(_handle, nil, _conv_id), do: :cold
  def attempt_warm_start(_handle, %{checkpoint_id: nil}, _conv_id), do: :cold
  def attempt_warm_start(_handle, %{checkpoint_id: ""}, _conv_id), do: :cold

  def attempt_warm_start(handle, %{checkpoint_id: id} = env, conv_id) do
    Output.publish_stage(conv_id, "checkpoint_restore", "started", %{checkpoint_id: id})

    # `restore_checkpoint/2` returns a bare `:ok` — `Fountain.Telemetry.span/3`
    # unwraps the `{result, metadata}` pair it is given, so the `{:ok, _}` this
    # used to match never occurred and a successful restore raised
    # CaseClauseError. Latent only because #652 kept `checkpoint_id` nil, so
    # this branch was unreachable.
    case Provisioning.restore_checkpoint(handle, id) do
      ok when ok == :ok or (is_tuple(ok) and elem(ok, 0) == :ok) ->
        Output.publish_stage(conv_id, "checkpoint_restore", "done", %{checkpoint_id: id})
        :warm_started

      {:error, reason} ->
        Logger.warning(
          "checkpoint #{id} on env #{env.name} restore failed (#{inspect(reason)}); clearing + cold provisioning"
        )

        Output.publish_stage(conv_id, "checkpoint_restore", "failed", %{
          checkpoint_id: id,
          reason: inspect(reason)
        })

        # Clear the stale checkpoint so future runs don't keep retrying.
        Fountain.Environments.update_environment(env, %{"checkpoint_id" => nil},
          actor: "system:conversation_server"
        )

        :cold
    end
  end

  @doc """
  Snapshot a fully provisioned machine so later conversations on the same
  environment can warm-start from it. Best-effort and off the caller's path,
  so it cannot delay a first turn.

  No catch-all clause: callers pass nil or an `%Environment{}`, both covered.
  A new caller passing anything else should crash loudly here rather than
  silently skip checkpointing.
  """
  def maybe_create_async(_handle, nil), do: :ok

  def maybe_create_async(_handle, %{checkpoint_id: id})
      when is_binary(id) and id != "",
      do: :ok

  def maybe_create_async(handle, %Environment{} = env) do
    if checkpoint_creation_enabled?() do
      Task.start(fn ->
        try do
          Provisioning.create_checkpoint(handle, env)
        rescue
          # Best-effort: if the env was deleted or the DB is gone (test
          # teardown), don't crash the Task and pollute logs.
          _ -> :ok
        end
      end)
    end

    :ok
  end

  # Off by default since #654: a checkpoint id is scoped to the sprite that
  # created it, and an environment's checkpoint is only ever restored into a
  # *different* sprite (sandboxes are per-conversation, with a fresh name each
  # time). Measured against the API — a fresh sprite lists only `Current`, and
  # restoring another sprite's `v1` answers `checkpoint not found: checkpoint
  # with path checkpoints/v1 not found`. So the warm start this feature exists
  # for cannot happen, and creating checkpoints only spends time and storage to
  # record an id that every later conversation will fail to restore.
  #
  # Left as a flag rather than deleted: if the platform grows a fork-from-
  # checkpoint or create-sprite-from-checkpoint call, this becomes a one-line
  # re-enable plus a restore that can finally work.
  defp checkpoint_creation_enabled? do
    Application.get_env(:fountain, :checkpoint_creation_enabled, false)
  end
end
