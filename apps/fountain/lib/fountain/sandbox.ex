defmodule Fountain.Sandbox do
  @moduledoc """
  The sandbox backend contract: one behaviour, one facade, one error taxonomy.

  Every conversation runs inside a sandbox owned by a *provider* (Sprites
  today; more to come). This module is both the `@behaviour` an adapter
  implements and the facade the rest of the application calls — call sites
  never name an adapter module, they dispatch through here on either a
  provider atom (creation-side operations) or the `provider` tag carried by
  a `Fountain.Sandbox.Handle`/`Fountain.Sandbox.Command`.

  The contract is the executable form of
  `docs/integrations/sprites-contract.md` and of ADR 0016 §5. The semantics
  below are normative for every adapter; the conformance suite pins them.

  ## Lifecycle semantics

    * `c:create/2` is **name-keyed and idempotent-adopting**: creating a name
      that already exists returns `{:ok, handle}` for the existing sandbox.
    * `c:get/1` must return `{:error, :not_found}` for a definitively absent
      sandbox and a *different* error for anything transient. Callers use the
      distinction to decide whether a parked disk (holding agent memory) may
      be given up — misclassifying a network blip as not-found loses data.
    * `c:destroy/1` tolerates an already-gone sandbox (`:ok`).
    * `c:list_all_names/0` returns the full account view or refuses with
      `{:error, :truncated}` — never a partial set that looks whole.
    * `c:suspend/1` / `c:resume/1` park and wake a sandbox. Adapters whose
      platform parks implicitly (scale-to-zero) implement them as no-ops but
      still advertise `:suspend` — the flag answers "does idle parking
      preserve the disk cheaply?", and the idle sweep destroys instead where
      it is absent. A failed suspend call degrades to destroy (an unparked
      sandbox keeps billing); a failed resume leaves the row suspended (the
      disk is the agent's memory).

  ## Exec semantics

    * `c:exec/4` blocks until the command exits and **never raises**: a
      nonzero exit is `{:ok, output, code}` (the script failed — readable),
      an unreachable sandbox is `{:error, reason}` (retriable by the caller).
    * `c:spawn/4` starts a streaming command. The adapter must deliver these
      messages, and only these, to the `:owner` pid:

          {:stdout, %{ref: ref}, data :: binary()}
          {:stderr, %{ref: ref}, data :: binary()}   # absent in tty mode
          {:exit,   %{ref: ref}, exit_code :: integer()}
          {:error,  %{ref: ref}, reason :: term()}   # transport failure; no :exit follows

      where `ref` equals the returned command's `ref` and the second element
      is any map carrying `:ref` — consumers must match `%{ref: ref}`, never
      an adapter's struct. Exactly one terminal frame (`:exit` or `:error`)
      arrives, after all output frames. **A stream that closes without an
      exit frame must be surfaced as `{:exit, %{ref: ref}, 0}`** — an adapter
      that drops the connection silently makes failed commands look
      successful.
    * `c:write_stdin/2` is **total**: writing to a command whose process has
      already exited returns `{:error, :command_exited}`, it never exits or
      raises in the caller (the #603 contract).
    * `c:attach/3` re-joins a detached session and **replays its buffered
      output from the beginning, then tails**. There is no offset parameter;
      callers de-duplicate by counting bytes already persisted per stream,
      which only works if replay starts at byte zero.

  ## Errors

  Adapters normalize provider error shapes into the closed `t:error/0`
  taxonomy so retry classification (`Fountain.Retry.transient?/1`) and
  not-found handling are provider-neutral.
  """

  alias Fountain.Sandbox.{Command, Handle, NetworkPolicy, Session}

  @typedoc "A sandbox backend identifier."
  @type provider :: atom()

  @typedoc "The Fountain-minted, provider-scoped sandbox name."
  @type name :: String.t()

  @typedoc """
  What a provider can do beyond the required operations.

    * `:suspend` — idle sandboxes can park with their disk preserved at
      negligible cost (implicitly via scale-to-zero, or via an explicit
      pause/stop call in `c:suspend/1`); the idle sweep destroys instead
      where absent
    * `:network_policy` — deny-capable egress policy
    * `:checkpoint` — checkpoint create/restore currently usable
    * `:attach` — detachable sessions with replay-from-start
    * `:tty` — PTY allocation on spawn
  """
  @type capability :: :suspend | :network_policy | :checkpoint | :attach | :tty

  @typedoc """
  The provider-neutral error taxonomy.

    * `:not_found` — the sandbox/session definitively does not exist
    * `:truncated` — a listing refused to return a partial view
    * `:not_supported` — the adapter does not implement this operation
    * `:command_exited` — stdin write raced the command's exit
    * `{:rate_limited, retry_after}` — throttled; transient
    * `{:unavailable, detail}` — 5xx / timeout / transport; transient
    * `{:denied, detail}` — 401/403; a credential problem, permanent
    * `{:invalid, detail}` — other 4xx; the caller's fault, permanent
    * `{:restore_failed, detail}` — a checkpoint restore reported failure
    * `{:write_failed, detail}` — stdin write failed for a non-exit reason
    * `{:provider, provider, detail}` — escape hatch; classified transient
  """
  @type error ::
          :not_found
          | :truncated
          | :not_supported
          | :command_exited
          | {:rate_limited, non_neg_integer() | nil}
          | {:unavailable, term()}
          | {:denied, term()}
          | {:invalid, term()}
          | {:restore_failed, term()}
          | {:write_failed, term()}
          | {:provider, provider(), term()}

  @typedoc "Normalized sandbox info from `c:get/1`. `:raw` is provider-shaped."
  @type info :: %{status: :running | :suspended | :unknown, raw: term()}

  # ── behaviour ──────────────────────────────────────────────────────────────

  @doc "The provider atom this adapter serves."
  @callback provider() :: provider()

  @doc "Capabilities this adapter currently offers (may be config-dependent)."
  @callback capabilities() :: MapSet.t(capability())

  @doc "Build a handle from a persisted name. Pure — no I/O."
  @callback build_handle(name()) :: Handle.t()

  @doc "Create (or adopt) the named sandbox."
  @callback create(name(), keyword()) :: {:ok, Handle.t()} | {:error, error()}

  @doc "Probe the sandbox. `{:error, :not_found}` is definitive absence."
  @callback get(Handle.t()) :: {:ok, info()} | {:error, error()}

  @doc "Destroy the sandbox. Already-gone is `:ok`."
  @callback destroy(Handle.t()) :: :ok | {:error, error()}

  @doc "Every sandbox name on the account, or a refusal — never a partial view."
  @callback list_all_names() :: {:ok, MapSet.t(name())} | {:error, error()}

  @doc "Explicitly park the sandbox. No-op where the platform parks implicitly."
  @callback suspend(Handle.t()) :: :ok | {:error, error()}

  @doc "Wake a parked sandbox, returning a fresh handle."
  @callback resume(Handle.t()) :: {:ok, Handle.t()} | {:error, error()}

  @doc "Write a file (creating parent directories). Options: `:mode`."
  @callback write_file(Handle.t(), path :: String.t(), iodata(), keyword()) ::
              :ok | {:error, error()}

  @doc """
  Run a command to completion. Options: `:env` (list of `{key, value}`
  pairs), `:dir`, `:timeout` (ms, default `:infinity`), `:stderr_to_stdout`.
  """
  @callback exec(Handle.t(), cmd :: String.t(), args :: [String.t()], keyword()) ::
              {:ok, output :: binary(), exit_code :: integer()} | {:error, error()}

  @doc """
  Start a streaming command. Options: `:owner`, `:env`, `:dir`, `:stdin`,
  `:tty`, `:detachable`. Messages per the moduledoc contract.
  """
  @callback spawn(Handle.t(), cmd :: String.t(), args :: [String.t()], keyword()) ::
              {:ok, Command.t()} | {:error, error()}

  @doc "Write to the command's stdin. Total — see the moduledoc."
  @callback write_stdin(Command.t(), iodata()) :: :ok | {:error, error()}

  @doc "Send stdin EOF."
  @callback close_stdin(Command.t()) :: :ok | {:error, error()}

  @doc """
  Stop the local command handle, terminating its transport. Total — an
  already-stopped command is `:ok`. For a detachable command the remote
  process keeps running (that is what reattach exists for); this only tears
  down this node's end.
  """
  @callback stop_command(Command.t()) :: :ok

  @doc "List the sandbox's detachable sessions."
  @callback list_sessions(Handle.t()) :: {:ok, [Session.t()]} | {:error, error()}

  @doc "Re-join a detached session; replays buffered output from the start."
  @callback attach(Handle.t(), session_id :: String.t(), keyword()) ::
              {:ok, Command.t()} | {:error, error()}

  @doc "Apply a deny-capable egress policy. `allow: []` must deny all egress."
  @callback apply_network_policy(Handle.t(), NetworkPolicy.t()) :: :ok | {:error, error()}

  @doc "Checkpoint the sandbox filesystem; returns the durable checkpoint id."
  @callback create_checkpoint(Handle.t(), keyword()) ::
              {:ok, checkpoint_id :: String.t()} | {:error, error()}

  @doc "Restore a checkpoint. A reported-failed restore is an error, not `:ok`."
  @callback restore_checkpoint(Handle.t(), checkpoint_id :: String.t()) ::
              :ok | {:error, error()}

  # ── facade ─────────────────────────────────────────────────────────────────

  @default_adapters %{sprites: Fountain.Sandbox.Sprites}

  @doc """
  The closed vocabulary of providers Fountain knows how to name.

  Knowing a provider is not the same as having it configured — this list is
  for schema-level validation; runtime enabledness is a config concern.
  """
  @spec known_providers() :: [String.t()]
  def known_providers, do: ~w(sprites e2b daytona)

  @doc "The adapter module for a provider. Raises on an unknown provider."
  @spec adapter_for(provider()) :: module()
  def adapter_for(provider) when is_atom(provider) do
    adapters = Application.get_env(:fountain, :sandbox_adapters, @default_adapters)

    case Map.fetch(adapters, provider) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown sandbox provider #{inspect(provider)} — configured: " <>
                inspect(Map.keys(adapters))
    end
  end

  @doc "The instance-default provider (`SANDBOX_PROVIDER`; validated at boot)."
  @spec default_provider() :: provider()
  def default_provider do
    Application.get_env(:fountain, :sandbox_default_provider, :sprites)
  end

  @doc """
  Whether a provider is usable on this instance: its adapter is registered
  **and** its credential is configured. Enabledness is runtime state — the
  schema validates against `known_providers/0`, selection validates against
  this.
  """
  @spec enabled?(provider()) :: boolean()
  def enabled?(provider) when is_atom(provider) do
    adapters = Application.get_env(:fountain, :sandbox_adapters, @default_adapters)
    Map.has_key?(adapters, provider) and credential_present?(provider)
  end

  @doc "Every provider currently usable on this instance."
  @spec enabled_providers() :: [provider()]
  def enabled_providers do
    known_providers()
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(&enabled?/1)
  end

  defp credential_present?(:sprites), do: Application.get_env(:fountain, :sprites_token) != nil
  defp credential_present?(:e2b), do: Application.get_env(:fountain, :e2b_api_key) != nil
  defp credential_present?(:daytona), do: Application.get_env(:fountain, :daytona_api_key) != nil
  # Non-production adapters (the in-memory Fake) carry no credentials; being
  # registered in :sandbox_adapters is what enables them.
  defp credential_present?(_other), do: true

  @doc "Whether a provider (or the provider owning a handle) has a capability."
  @spec supports?(provider() | Handle.t(), capability()) :: boolean()
  def supports?(%Handle{provider: provider}, capability), do: supports?(provider, capability)

  def supports?(provider, capability) when is_atom(provider) do
    MapSet.member?(adapter_for(provider).capabilities(), capability)
  end

  @doc "Build a handle for a persisted sandbox name. Pure — no I/O."
  @spec build_handle(provider(), name()) :: Handle.t()
  def build_handle(provider, name), do: adapter_for(provider).build_handle(name)

  @doc "Create (or adopt) a sandbox on the given provider."
  @spec create(provider(), name(), keyword()) :: {:ok, Handle.t()} | {:error, error()}
  def create(provider, name, opts \\ []), do: adapter_for(provider).create(name, opts)

  @doc "Every sandbox name the provider's account holds."
  @spec list_all_names(provider()) :: {:ok, MapSet.t(name())} | {:error, error()}
  def list_all_names(provider \\ default_provider()) do
    adapter_for(provider).list_all_names()
  end

  @doc "Probe a sandbox."
  @spec get(Handle.t()) :: {:ok, info()} | {:error, error()}
  def get(%Handle{} = handle), do: adapter(handle).get(handle)

  @doc "Destroy a sandbox."
  @spec destroy(Handle.t()) :: :ok | {:error, error()}
  def destroy(%Handle{} = handle), do: adapter(handle).destroy(handle)

  @doc "Explicitly park a sandbox."
  @spec suspend(Handle.t()) :: :ok | {:error, error()}
  def suspend(%Handle{} = handle), do: adapter(handle).suspend(handle)

  @doc "Wake a parked sandbox."
  @spec resume(Handle.t()) :: {:ok, Handle.t()} | {:error, error()}
  def resume(%Handle{} = handle), do: adapter(handle).resume(handle)

  @doc "Write a file into the sandbox."
  @spec write_file(Handle.t(), String.t(), iodata(), keyword()) :: :ok | {:error, error()}
  def write_file(%Handle{} = handle, path, data, opts \\ []) do
    adapter(handle).write_file(handle, path, data, opts)
  end

  @doc "Run a command to completion."
  @spec exec(Handle.t(), String.t(), [String.t()], keyword()) ::
          {:ok, binary(), integer()} | {:error, error()}
  def exec(%Handle{} = handle, cmd, args, opts \\ []) do
    adapter(handle).exec(handle, cmd, args, opts)
  end

  @doc "Start a streaming command."
  @spec spawn(Handle.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Command.t()} | {:error, error()}
  def spawn(%Handle{} = handle, cmd, args, opts \\ []) do
    adapter(handle).spawn(handle, cmd, args, opts)
  end

  @doc "Write to a running command's stdin. Total."
  @spec write_stdin(Command.t(), iodata()) :: :ok | {:error, error()}
  def write_stdin(%Command{} = command, data) do
    adapter_for(command.provider).write_stdin(command, data)
  end

  @doc "Send stdin EOF to a running command."
  @spec close_stdin(Command.t()) :: :ok | {:error, error()}
  def close_stdin(%Command{} = command) do
    adapter_for(command.provider).close_stdin(command)
  end

  @doc "Stop the local command handle. Total."
  @spec stop_command(Command.t()) :: :ok
  def stop_command(%Command{} = command) do
    adapter_for(command.provider).stop_command(command)
  end

  @doc "List a sandbox's detachable sessions."
  @spec list_sessions(Handle.t()) :: {:ok, [Session.t()]} | {:error, error()}
  def list_sessions(%Handle{} = handle), do: adapter(handle).list_sessions(handle)

  @doc "Re-join a detached session."
  @spec attach(Handle.t(), String.t(), keyword()) :: {:ok, Command.t()} | {:error, error()}
  def attach(%Handle{} = handle, session_id, opts \\ []) do
    adapter(handle).attach(handle, session_id, opts)
  end

  @doc "Apply an egress policy."
  @spec apply_network_policy(Handle.t(), NetworkPolicy.t()) :: :ok | {:error, error()}
  def apply_network_policy(%Handle{} = handle, %NetworkPolicy{} = policy) do
    adapter(handle).apply_network_policy(handle, policy)
  end

  @doc "Checkpoint the sandbox; returns the checkpoint id."
  @spec create_checkpoint(Handle.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def create_checkpoint(%Handle{} = handle, opts \\ []) do
    adapter(handle).create_checkpoint(handle, opts)
  end

  @doc "Restore a checkpoint into the sandbox."
  @spec restore_checkpoint(Handle.t(), String.t()) :: :ok | {:error, error()}
  def restore_checkpoint(%Handle{} = handle, checkpoint_id) do
    adapter(handle).restore_checkpoint(handle, checkpoint_id)
  end

  defp adapter(%Handle{provider: provider}), do: adapter_for(provider)
end
