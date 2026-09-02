defmodule Managoat.Runner.Host.Local do
  @moduledoc """
  The reference `Managoat.Runner.Host`: a plain `Registry` (`keys: :unique`)
  on one node, and no reaction to heartbeats or presence.

  Start it under a supervisor and name it in config:

      children = [Managoat.Runner.Host.Local]
      config :managoat_runner, host: Managoat.Runner.Host.Local

  A registration is tied to the connection process: when that process exits
  the `Registry` drops it, which is the same guarantee a clustered host
  gives. The library's tests run against this host; a platform that runs
  more than one node, keeps a row per runner or broadcasts presence
  implements the behaviour over its own registry instead.
  """

  @behaviour Managoat.Runner.Host

  @registry __MODULE__

  @doc "The `Registry` name this host registers connections in."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "A child spec for the registry, so the host can sit in a supervision tree."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts \\ []) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc "Start the registry, linked to the caller."
  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    Registry.start_link(keys: :unique, name: @registry)
  end

  @impl true
  def register(runner_id, meta) when is_binary(runner_id) and is_map(meta) do
    case Registry.register(@registry, runner_id, meta) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  @impl true
  def unregister(runner_id) when is_binary(runner_id) do
    Registry.unregister(@registry, runner_id)
  end

  @impl true
  def whereis(runner_id) when is_binary(runner_id) do
    case Registry.lookup(@registry, runner_id) do
      [{pid, _meta}] -> pid
      [] -> nil
    end
  end

  @impl true
  def online do
    Registry.select(@registry, [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  @impl true
  def heartbeat(_runner_id), do: :ok

  @impl true
  def presence(_runner_id, _status, _meta), do: :ok
end
