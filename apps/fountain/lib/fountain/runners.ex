defmodule Fountain.Runners do
  @moduledoc """
  Self-hosted runners: machines the user owns that run the `fountain runner`
  daemon and serve the `Managoat.Sandbox` contract for that user (ADR 0022).

  Two kinds of state live here and they are deliberately separate:

    * the `runners` **rows** — identity (`user_id`, `name`) and what the
      daemon last reported (host, OS, version, timestamps). Upserted on
      connect, tenant-scoped like everything else;
    * the **registry** — `Fountain.RunnerRegistry` (Horde, cluster-wide) maps
      a runner id to the connection process currently holding its socket.
      A runner is *online* exactly while such a process is registered.

  The adapter (`Fountain.Sandbox.Runner`) only ever asks the registry; the
  UI and API read the rows and ask `online?/1`. Sandbox names on this
  provider carry the runner id (`runner-<32 hex>-<8 hex>`) because the
  sandbox contract hands adapters nothing but the name — see
  `mint_sandbox_name/1` / `parse_sandbox_name/1`.
  """

  import Ecto.Query, warn: false

  alias Fountain.Audit
  alias Fountain.Repo
  alias Fountain.Runners.Runner

  @registry Fountain.RunnerRegistry

  # ── rows ───────────────────────────────────────────────────────────────────

  @doc "Every runner the user has ever connected, newest connection first."
  @spec list_runners(binary()) :: [Runner.t()]
  def list_runners(user_id) do
    Runner
    |> where([r], r.user_id == ^user_id)
    |> order_by([r], desc: r.connected_at, asc: r.name)
    |> Repo.all()
  end

  @doc "A runner by id, scoped to its owner."
  @spec get_runner(binary(), binary()) :: Runner.t() | nil
  def get_runner(id, user_id) do
    Repo.get_by(Runner, id: id, user_id: user_id)
  end

  @doc "A runner by name, scoped to its owner."
  @spec get_runner_by_name(binary(), String.t()) :: Runner.t() | nil
  def get_runner_by_name(user_id, name) do
    Repo.get_by(Runner, user_id: user_id, name: name)
  end

  @doc """
  Upsert the runner row for a connecting daemon: `(user_id, name)` is the
  identity; host details and `connected_at`/`last_seen_at` are refreshed.

  The first connection of a name records `runner.registered`; reconnects
  are silent (a flaky network would otherwise write an audit row per retry).
  `opts` carries `:actor` / `:request_ip` as everywhere else.
  """
  @spec register(binary(), map(), keyword()) :: {:ok, Runner.t()} | {:error, Ecto.Changeset.t()}
  def register(user_id, attrs, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end)
    name = attrs["name"]

    attrs =
      attrs
      |> Map.take(~w(name hostname os arch version root))
      |> Map.merge(%{"connected_at" => now, "last_seen_at" => now, "user_id" => user_id})

    case get_runner_by_name(user_id, name) do
      nil ->
        %Runner{}
        |> Runner.changeset(attrs)
        |> Repo.insert()
        |> audited("runner.registered", opts)

      %Runner{} = runner ->
        runner
        |> Runner.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Stamp `last_seen_at`; called from the connection's heartbeat. Silent."
  @spec touch(binary()) :: :ok
  def touch(runner_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Runner
    |> where([r], r.id == ^runner_id)
    |> Repo.update_all(set: [last_seen_at: now])

    :ok
  end

  @doc """
  Forget a runner. A live connection for it is closed (the daemon will
  reconnect and re-register itself, which is the honest outcome — deleting a
  row does not switch a machine off). Sandbox rows minted on it stay put:
  their names still say which runner they lived on.
  """
  @spec delete_runner(Runner.t(), keyword()) :: {:ok, Runner.t()} | {:error, Ecto.Changeset.t()}
  def delete_runner(%Runner{} = runner, opts \\ []) do
    result = runner |> Repo.delete() |> audited("runner.deleted", opts)

    case {result, whereis(runner.id)} do
      {{:ok, _}, pid} when is_pid(pid) -> send(pid, {:runner_deleted, runner.id})
      _ -> :ok
    end

    result
  end

  # ── registry ───────────────────────────────────────────────────────────────

  @doc "The registry name; the connection process registers itself here."
  def registry, do: @registry

  @doc "The `{:via, ...}` name for a runner's connection process."
  def via(runner_id), do: {:via, Horde.Registry, {@registry, {:runner, runner_id}}}

  @doc "The connection process holding the runner's socket, or nil."
  @spec whereis(binary()) :: pid() | nil
  def whereis(runner_id) do
    case Horde.Registry.lookup(@registry, {:runner, runner_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Whether the runner has a live connection right now."
  @spec online?(Runner.t() | binary()) :: boolean()
  def online?(%Runner{id: id}), do: online?(id)
  def online?(runner_id) when is_binary(runner_id), do: whereis(runner_id) != nil

  @doc "The ids of every runner currently connected, cluster-wide, with owner."
  @spec online_runner_ids() :: [{binary(), binary()}]
  def online_runner_ids do
    @registry
    |> Horde.Registry.select([
      {{{:runner, :"$1"}, :_, %{user_id: :"$2"}}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.uniq()
  end

  @doc "The user's runners, each with `:online` set."
  @spec list_runners_with_status(binary()) :: [map()]
  def list_runners_with_status(user_id) do
    user_id
    |> list_runners()
    |> Enum.map(&%{runner: &1, online: online?(&1)})
  end

  @doc """
  The runner a new sandbox for this user should live on: the most recently
  connected one that is online now. Per-agent pinning is not built (ADR 0022).
  """
  @spec pick_runner(binary()) :: {:ok, Runner.t()} | {:error, :no_runner_online}
  def pick_runner(user_id) do
    user_id
    |> list_runners()
    |> Enum.find(&online?/1)
    |> case do
      nil -> {:error, :no_runner_online}
      runner -> {:ok, runner}
    end
  end

  # ── presence broadcasts ────────────────────────────────────────────────────

  @doc """
  Subscribe to `{:runner_online, runner_id}` / `{:runner_offline, runner_id}`
  for `user_id`'s runners — sent by the connection process as it registers
  and as it goes away (#834). A roster of runner-backed teammates re-reads
  presence on either rather than polling.
  """
  def subscribe(user_id) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(Fountain.PubSub, topic(user_id))

  @doc false
  def broadcast_presence(user_id, runner_id, :online)
      when is_binary(user_id) and is_binary(runner_id),
      do: Phoenix.PubSub.broadcast(Fountain.PubSub, topic(user_id), {:runner_online, runner_id})

  def broadcast_presence(user_id, runner_id, :offline)
      when is_binary(user_id) and is_binary(runner_id),
      do: Phoenix.PubSub.broadcast(Fountain.PubSub, topic(user_id), {:runner_offline, runner_id})

  defp topic(user_id), do: "runners:#{user_id}"

  # ── sandboxes on runners ───────────────────────────────────────────────────

  @doc """
  What a runner-backed sandbox sits on (#834): `%{runner: %Runner{} | nil,
  online: boolean, path: String.t() | nil}` — the row (nil when the runner
  was forgotten), whether its connection is up right now, and the sandbox
  directory on that machine (`<root>/<name>`, the daemon's layout; nil when
  the row does not know its root). `nil` for any other provider. Ownership:
  the sandbox row carries its `user_id`, and the runner is fetched under it.
  """
  @spec for_sandbox(map() | nil) ::
          %{runner: Runner.t() | nil, online: boolean(), path: String.t() | nil} | nil
  def for_sandbox(%{provider: "runner", sprite_name: name, user_id: user_id})
      when is_binary(name) do
    case parse_sandbox_name(name) do
      {:ok, runner_id} ->
        runner = get_runner(runner_id, user_id)

        %{
          runner: runner,
          online: online?(runner_id),
          path: runner && runner.root && Path.join(runner.root, name)
        }

      :error ->
        nil
    end
  end

  def for_sandbox(_), do: nil

  @doc """
  Whether the machine behind a runner-backed sandbox is connected right now;
  `true` for every other provider (a hosted sandbox has no machine to be
  off). Registry only — no query — so presence can ask per roster row.
  """
  @spec sandbox_online?(map() | nil) :: boolean()
  def sandbox_online?(%{provider: "runner", sprite_name: name}) when is_binary(name) do
    case parse_sandbox_name(name) do
      {:ok, runner_id} -> online?(runner_id)
      :error -> true
    end
  end

  def sandbox_online?(_), do: true

  # ── sandbox names ──────────────────────────────────────────────────────────

  @doc """
  Mint a sandbox name on the user's current runner. The runner id rides in the
  name because `Managoat.Sandbox` hands an adapter nothing else.
  """
  @spec mint_sandbox_name(binary()) :: {:ok, String.t()} | {:error, :no_runner_online}
  def mint_sandbox_name(user_id) do
    with {:ok, runner} <- pick_runner(user_id) do
      {:ok, sandbox_name_for(runner.id)}
    end
  end

  @doc "The sandbox name shape for a runner id: `runner-<32 hex>-<8 hex>`."
  @spec sandbox_name_for(binary()) :: String.t()
  def sandbox_name_for(runner_id) do
    short = Ecto.UUID.generate() |> binary_part(0, 8)
    "runner-#{String.replace(runner_id, "-", "")}-#{short}"
  end

  @doc "Recover the runner id (as a dashed UUID) from a sandbox name."
  @spec parse_sandbox_name(String.t()) :: {:ok, binary()} | :error
  def parse_sandbox_name("runner-" <> rest) do
    with <<hex::binary-size(32), "-", _short::binary>> <- rest,
         {:ok, uuid} <- hex |> dashed() |> Ecto.UUID.cast() do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  def parse_sandbox_name(_), do: :error

  defp dashed(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ),
       do: "#{a}-#{b}-#{c}-#{d}-#{e}"

  # ── audit ──────────────────────────────────────────────────────────────────

  defp audited({:ok, %Runner{} = runner} = ok, action, opts) do
    metadata =
      %{"hostname" => runner.hostname, "os" => runner.os, "arch" => runner.arch}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    Audit.record_resource(action, "runner", runner, Keyword.put(opts, :metadata, metadata))
    ok
  end

  defp audited(other, _action, _opts), do: other
end
