defmodule Fountain.Runners.Host do
  @moduledoc """
  Fountain's `Managoat.Runner.Host`: the runner library's view of this
  platform.

  The registry is `Fountain.RunnerRegistry` (Horde, cluster-wide, started in
  `Fountain.Application`), so a connection registered on one node is found
  from any other. `meta` is `%{user_id: ...}`, put there by
  `FountainWeb.RunnerController` at upgrade time; it is what `online/0` hands
  back for `Runners.online_runner_ids/0` and what `presence/3` needs to
  broadcast to the owner's team surface. The heartbeat stamps the row's
  `last_seen_at`.
  """

  @behaviour Managoat.Runner.Host

  alias Fountain.Runners

  @registry Fountain.RunnerRegistry

  @impl true
  def register(runner_id, meta) when is_binary(runner_id) and is_map(meta) do
    case Horde.Registry.register(@registry, {:runner, runner_id}, meta) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  @impl true
  def unregister(runner_id) when is_binary(runner_id) do
    Horde.Registry.unregister(@registry, {:runner, runner_id})
  end

  @impl true
  def whereis(runner_id) when is_binary(runner_id) do
    case Horde.Registry.lookup(@registry, {:runner, runner_id}) do
      [{pid, _meta}] -> pid
      [] -> nil
    end
  end

  @impl true
  def online do
    Horde.Registry.select(@registry, [{{{:runner, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  @impl true
  def heartbeat(runner_id), do: Runners.touch(runner_id)

  @impl true
  def presence(runner_id, status, %{user_id: user_id}) when status in [:online, :offline] do
    Runners.broadcast_presence(user_id, runner_id, status)
  end
end
