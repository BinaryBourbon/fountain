defmodule Fountain.Buzz.Manager do
  @moduledoc """
  Starts and stops hosted `buzz-acp` harnesses, one per Buzz identity, across the
  cluster (ADR 0020, Phase 1 — gate #736, increment 2).

  A harness is a `Fountain.Buzz.Harness` process registered in
  `Fountain.BuzzRegistry` under its identity id and supervised by
  `Fountain.BuzzSupervisor` (a `Horde.DynamicSupervisor`), so exactly one runs
  per identity cluster-wide and it survives a node loss the same way a
  `ConversationServer` does.

  This module is the seam between the tenant-aware context and the process tree:
  it calls `Fountain.Buzz.harness_launch/2` (which mints the API key and decrypts
  the vault) and hands the resulting spec to the supervisor. It also owns the one
  correctness subtlety that split introduces — a launch mints a credential
  *before* the supervisor can say whether a harness already exists, so every path
  that does not end in a running harness revokes the key it minted, or a race
  would leak standing credentials.
  """

  require Logger

  alias Fountain.Buzz
  alias Fountain.Buzz.{BuzzIdentity, Harness}

  @registry Fountain.BuzzRegistry
  @supervisor Fountain.BuzzSupervisor

  @doc "The via-tuple a harness for `identity_id` is registered under."
  def via(identity_id), do: {:via, Horde.Registry, {@registry, identity_id}}

  @doc "The harness pid for `identity_id`, or nil if none is running."
  def whereis(identity_id) do
    case Horde.Registry.lookup(@registry, identity_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Whether a harness is running for `identity_id` (anywhere in the cluster)."
  def running?(identity_id), do: whereis(identity_id) != nil

  @doc """
  Ensure a harness is running for `identity`. Idempotent: if one already runs,
  returns it without minting a credential. Otherwise mints the launch's API key,
  builds the env, and starts the supervised harness.

  `opts` are forwarded to `Fountain.Buzz.harness_launch/2` (`:buzz_acp_path`,
  `:base_url`, `:agents`, attribution). Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_harness(BuzzIdentity.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_harness(%BuzzIdentity{} = identity, opts \\ []) do
    case whereis(identity.id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        with {:ok, launch} <- Buzz.harness_launch(identity, opts) do
          start_child(identity, launch)
        end
    end
  end

  @doc """
  Stop the harness for `identity_id` if one is running. The harness's own
  `terminate` revokes its launch key. Returns `:ok` whether or not one was found.
  """
  def stop_harness(identity_id) do
    case whereis(identity_id) do
      nil -> :ok
      pid -> Horde.DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  defp start_child(%BuzzIdentity{} = identity, launch) do
    child = %{
      id: identity.id,
      start: {Harness, :start_link, [harness_opts(identity, launch)]},
      # The harness restarts its own port; if the harness process itself dies we
      # want Horde to bring it back, but a deliberate stop is terminal.
      restart: :transient,
      type: :worker,
      shutdown: 10_000
    }

    case Horde.DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Another node won the race between our `whereis` and this call. The key
        # we just minted has no harness to own it — revoke it rather than leak it.
        revoke_orphaned_key(identity, launch)
        {:ok, pid}

      {:error, reason} = err ->
        revoke_orphaned_key(identity, launch)

        Logger.error(
          "buzz harness failed to start: identity=#{identity.id} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp harness_opts(%BuzzIdentity{} = identity, launch) do
    [
      name: via(identity.id),
      command: launch.command,
      args: launch.args,
      env: launch.env,
      label: identity.id,
      on_stop: fn -> Buzz.revoke_launch_key(identity, launch.api_key_id) end
    ]
  end

  defp revoke_orphaned_key(%BuzzIdentity{} = identity, launch) do
    Buzz.revoke_launch_key(identity, launch.api_key_id)
  rescue
    e -> Logger.error("failed to revoke orphaned buzz launch key: #{inspect(e)}")
  end
end
