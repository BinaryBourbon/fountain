defmodule FountainBuzz.Manager do
  @moduledoc """
  Starts and stops hosted `buzz-acp` harnesses, one per Buzz identity, across the
  cluster (ADR 0020, Phase 1 — gate #736, increment 2).

  A harness is a `FountainBuzz.Harness` process registered in
  `FountainBuzz.Registry` under its identity id and supervised by
  `FountainBuzz.Supervisor` (a `Horde.DynamicSupervisor`), so exactly one runs
  per identity cluster-wide and it survives a node loss the same way a
  `ConversationServer` does.

  This module is the seam between the tenant-aware context and the process tree:
  it calls `FountainBuzz.harness_launch/2` (which mints the API key and decrypts
  the vault) and hands the resulting spec to the supervisor.

  ## The child spec carries the identity id and nothing else

  Horde stores every child spec in a CRDT and **replays it** — on a node loss,
  on a rebalance, and on every deploy, when the old node's supervisor terminates
  the harness and the new node's starts it again from the stored spec. So
  anything resolved at `start_harness/2` time and put in the spec is frozen at
  that moment, for the life of the identity. Two things bit (2026-08-16, the
  FizzTheShark identity): the launcher path
  (`/app/lib/fountain-<version>/priv/buzz-acp-launch.sh`) went stale on the next
  version bump and the harness crash-looped on `No such file` after every
  restart; and the minted `FOUNTAIN_API_KEY` was **revoked by the old node's
  `terminate/2`** and then replayed by the new node, so a harness that did start
  drove `fountain acp` with a dead credential. The `ConversationServer` learned
  the same lesson about its initial prompt.

  So the spec is `{Manager, :start_harness_link, [identity_id, opts]}` and the
  launch — identity re-read, vault decrypted, key minted, launcher path resolved
  — happens inside that function, on whichever node is starting the child, every
  time it starts. `opts` are the config overrides only (`:buzz_acp_path`,
  `:base_url`, `:agents`, `:actor`); they are safe to store.
  """

  require Logger

  alias FountainBuzz, as: Buzz
  alias FountainBuzz.{Identity, Harness}

  @registry FountainBuzz.Registry
  @supervisor FountainBuzz.Supervisor

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

  @doc "Number of Buzz harnesses running across the cluster."
  @spec running_count() :: non_neg_integer()
  def running_count do
    case Horde.Registry.count(@registry) do
      :undefined -> 0
      count -> count
    end
  end

  @doc """
  Ensure a harness is running for `identity`. Idempotent: if one already runs,
  returns it without minting a credential. Otherwise starts the supervised
  harness, whose start resolves the launch (mints the API key, decrypts the
  vault, builds the env) — see the moduledoc for why that happens in the child
  and not here.

  `opts` are forwarded to `FountainBuzz.harness_launch/2` (`:buzz_acp_path`,
  `:base_url`, `:agents`, attribution) and stored in the child spec, so they must
  not carry anything that goes stale. Returns `{:ok, pid}` or `{:error, reason}`;
  a launch error (`:no_buzz_acp_path`, `:vault_not_found`, …) surfaces here.
  """
  @spec start_harness(Identity.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_harness(%Identity{} = identity, opts \\ []) do
    case whereis(identity.id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_child(identity, opts)
    end
  end

  @doc false
  # The child's start function. Runs under `FountainBuzz.Supervisor` on whichever
  # node is starting this child — first start, restart after a crash, or Horde
  # replaying the spec after a deploy — so everything here is resolved fresh
  # each time. `:ignore` drops the spec for an identity that no longer exists or
  # is disabled; Horde would otherwise carry it forever.
  def start_harness_link(identity_id, opts) do
    # ownership: a supervisor start has no requester; the identity was
    # tenant-scoped when it was enabled, and every launch is scoped to its
    # user_id inside harness_launch/2.
    case Buzz._unsafe_get_identity(identity_id) do
      %Identity{enabled: true} = identity ->
        with {:ok, launch} <- Buzz.harness_launch(identity, opts) do
          case Harness.start_link(harness_opts(identity, launch)) do
            {:ok, pid} ->
              {:ok, pid}

            other ->
              # The key was minted for a harness that never came up.
              revoke_orphaned_key(identity, launch)
              other
          end
        end

      _ ->
        :ignore
    end
  end

  @doc """
  Stop the harness for `identity_id` if one is running. The harness's own
  `terminate` revokes its launch key. Returns `:ok` whether or not one was found.

  Synchronous, and it waits for the launcher OS process to exit so a completed
  stop means the launch's executable and pipes are free (#1469). A buzz-acp that
  handles SIGTERM goes in milliseconds; one that ignores it costs the launcher's
  five-second grace, capped at `Harness`'s six. Callers on a request path — the
  buzz-agent create, update and delete endpoints — pay that tail.
  """
  def stop_harness(identity_id) do
    case whereis(identity_id) do
      nil -> :ok
      pid -> Horde.DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc """
  Bounce the harness for `identity` so a launch resolved from the *current*
  identity row takes effect — a converging deploy that changed the author gate,
  the environment override, the relay or the display name (#790). Stops any
  running harness (its `terminate` revokes the old key), waits for the registry
  to drop it, then starts afresh. When none was running this is just
  `start_harness/2`. Returns what `start_harness/2` returns.
  """
  @spec restart_harness(Identity.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def restart_harness(%Identity{} = identity, opts \\ []) do
    :ok = stop_harness(identity.id)
    await_unregistered(identity.id, 50)
    start_harness(identity, opts)
  end

  # `terminate_child` is synchronous, but the registry learns of the exit by
  # monitor; give it a moment so `start_harness`'s `whereis` does not hand back
  # the dead pid.
  defp await_unregistered(_identity_id, 0), do: :ok

  defp await_unregistered(identity_id, tries) do
    if running?(identity_id) do
      Process.sleep(20)
      await_unregistered(identity_id, tries - 1)
    else
      :ok
    end
  end

  defp start_child(%Identity{} = identity, opts) do
    child = %{
      id: identity.id,
      start: {__MODULE__, :start_harness_link, [identity.id, opts]},
      # The harness restarts its own port; if the harness process itself dies we
      # want Horde to bring it back, but a deliberate stop is terminal.
      restart: :transient,
      type: :worker,
      shutdown: 10_000
    }

    case Horde.DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} ->
        {:ok, pid}

      # Another node won the race between our `whereis` and this call. Nothing
      # was minted on this side: the launch lives in the child's start.
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      :ignore ->
        {:error, :identity_not_enabled}

      {:error, reason} = err ->
        Logger.error(
          "buzz harness failed to start: identity=#{identity.id} reason=#{inspect(reason)}"
        )

        err
    end
  end

  defp harness_opts(%Identity{} = identity, launch) do
    [
      name: via(identity.id),
      command: launch.command,
      args: launch.args,
      env: launch.env,
      launcher: launcher_path(),
      label: identity.id,
      on_stop: fn -> Buzz.revoke_launch_key(identity, launch.api_key_id) end
    ]
  end

  # The port middleman that reaps buzz-acp on stop (priv/buzz-acp-launch.sh,
  # shipped in the release). Config can override the path; the app-dir default
  # resolves in dev, test and the release alike.
  defp launcher_path do
    Application.get_env(:fountain_buzz, :buzz_acp_launcher) ||
      Application.app_dir(:fountain_buzz, "priv/buzz-acp-launch.sh")
  end

  defp revoke_orphaned_key(%Identity{} = identity, launch) do
    Buzz.revoke_launch_key(identity, launch.api_key_id)
  rescue
    e -> Logger.error("failed to revoke orphaned buzz launch key: #{inspect(e)}")
  end
end
