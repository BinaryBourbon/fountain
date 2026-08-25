defmodule Fountain.Conversations.Provisioning do
  @moduledoc """
  Provisioning steps that run inside a freshly-created sandbox, before the
  runtime CLI is spawned. Each step publishes its own stage events so the
  UI/SSE clients can show progress.

  Order in `ConversationServer.handle_continue(:provision)`:
    1. mount skills (inline writes + skills.sh github installs — github
       installs need network and run before the policy lockdown)
    2. `install_packages/4` (apt/npm — needs unrestricted network; must
       run before the policy lockdown so apt can reach package repos)
    3. `apply_network_policy/3` (sandbox API call — fast)
    4. `clone_repositories/4` (git clone — slow)
    5. user's `setup_script` (whatever they supplied)
    6. write runtime-specific config (e.g. claude `~/.claude.json`)

  Each step is a no-op when the corresponding field is empty, so legacy
  environments with bare config (just a name) provision instantly.

  Everything here talks to the sandbox through `Fountain.Sandbox`; nothing
  provider-shaped (rule structs, checkpoint streams) appears at this level.
  """

  alias Fountain.Conversations
  alias Fountain.Environments.Environment
  alias Fountain.Retry
  alias Fountain.Sandbox
  alias Fountain.Sandbox.Handle
  alias Fountain.Sandbox.NetworkPolicy

  require Logger

  @env_file "/home/sprite/.env"

  @doc """
  Write the machine's env (runtime defaults + env_vars + secrets) to
  `/home/sprite/.env` so a `setup_script` that does `source .env` picks up
  the variables. Mirrors the legacy AoD's `env_file.py`.

  The per-conversation identity — `FOUNTAIN_TOKEN`, `FOUNTAIN_CONVERSATION_ID`,
  `TRACEPARENT` — is not in this file: callers pass the env through
  `Fountain.Conversations.Identity.disk_env/1` first. The file is shared by
  every conversation on the machine; the identity reaches each process as
  spawn env instead.

  Written with mode 600, and `chmod 600` again after the write as defense
  in depth — other sandbox users (if any) must not be able to read tokens.
  """
  def write_env_file(_handle, sprite_env) when sprite_env in [nil, []], do: :ok

  def write_env_file(handle, sprite_env) do
    body = render_env_file(sprite_env)

    case Retry.with_backoff(fn -> Sandbox.write_file(handle, @env_file, body, mode: 0o600) end,
           label: "env file write"
         ) do
      :ok ->
        # Ignore chmod errors — we still wrote the file (already mode 600).
        # Defense in depth, not a hard requirement.
        _ = Sandbox.exec(handle, "chmod", ["600", @env_file], timeout: 5_000)
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def render_env_file(sprite_env) do
    sprite_env
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{shell_escape_value(to_string(v))}" end)
    |> Kernel.<>("\n")
  end

  # Always single-quote, escaping inner single quotes as '\''.
  #
  # This previously detected `$`, backtick and backslash and then wrapped the
  # value in *double* quotes, where all three remain active. The file is
  # explicitly meant to be `source`d by a user's setup_script, so a secret whose
  # value contained $(...) or `...` executed on source. A value containing a
  # newline also silently corrupted the file, since nothing quoted it.
  #
  # Single quotes are inert in shell: the only character needing treatment is
  # the single quote itself, and newlines survive intact.
  defp shell_escape_value(v), do: shell_quote(v)

  # ── checkpoint create / restore ───────────────────────────────────────────

  @doc """
  Create a checkpoint of the fully-provisioned sandbox. The checkpoint id
  is persisted onto the environment row so subsequent conversations can
  warm-start from it instead of redoing packages/repos/setup_script.

  Best-effort — failures are logged and don't block the conversation.
  Caller typically wraps in `Task.start/1` so the user's first turn
  isn't gated on the checkpoint upload.

  The provider-specific mechanics (stream draining, id resolution) live in
  the adapter; `Fountain.Sandbox.create_checkpoint/2` returns only when the
  checkpoint durably exists, with its id.
  """
  def create_checkpoint(_handle, nil), do: {:error, :no_env}

  def create_checkpoint(handle, %Environment{} = env) do
    Fountain.Telemetry.span([:checkpoint, :create], %{env_id: env.id}, fn ->
      # Retried: a duplicate checkpoint from a lost-response retry is a
      # harmless orphan, so the call is idempotent enough.
      case Retry.with_backoff(
             fn -> Sandbox.create_checkpoint(handle, comment: "aod env #{env.name}") end,
             label: "checkpoint create"
           ) do
        {:ok, checkpoint_id} ->
          {:ok, _} =
            Fountain.Environments.update_environment(
              env,
              %{"checkpoint_id" => checkpoint_id},
              actor: "system:provisioning"
            )

          {{:ok, checkpoint_id}, %{outcome: :ok, checkpoint_id: checkpoint_id}}

        {:error, reason} ->
          Logger.warning("checkpoint create failed for env #{env.name}: #{inspect(reason)}")
          {{:error, reason}, %{outcome: :failed, reason: inspect(reason)}}
      end
    end)
  end

  @doc """
  Restore a sandbox from a saved checkpoint. Fully complete on return.
  Returns `:ok` on success or `{:error, reason}` if the checkpoint is
  gone / restore failed; the caller should clear `env.checkpoint_id` and
  fall back to fresh provisioning.
  """
  def restore_checkpoint(_handle, nil), do: {:error, :no_checkpoint}
  def restore_checkpoint(_handle, ""), do: {:error, :no_checkpoint}

  def restore_checkpoint(handle, checkpoint_id) when is_binary(checkpoint_id) do
    Fountain.Telemetry.span(
      [:checkpoint, :restore],
      %{checkpoint_id: checkpoint_id},
      fn ->
        # A reported-failed restore comes back as {:error, {:restore_failed, _}}
        # (permanent, not retried); only transport-level failures retry.
        case Retry.with_backoff(fn -> Sandbox.restore_checkpoint(handle, checkpoint_id) end,
               label: "checkpoint restore"
             ) do
          :ok ->
            {:ok, %{outcome: :ok}}

          {:error, reason} ->
            Logger.warning("checkpoint restore failed: #{inspect(reason)}")
            {{:error, reason}, %{outcome: :failed, reason: inspect(reason)}}
        end
      end
    )
  end

  # ── packages ──────────────────────────────────────────────────────────────

  @doc """
  Install OS / language packages declared on the env. Recognized keys:

      packages: %{
        "apt" => ["jq", "ripgrep"],
        "npm" => ["typescript", "@anthropic-ai/sdk"]
      }

  Anything else is silently ignored. Returns `:ok` on success, `{:error,
  {step, exit_code, output}}` on first failure (sandbox kept alive so the
  caller can decide whether to destroy).
  """
  def install_packages(_handle, nil, _sprite_env, _conv_id), do: :ok

  def install_packages(handle, %Environment{} = env, sprite_env, conv_id) do
    case build_package_commands(env.packages || %{}) do
      [] ->
        :ok

      cmds ->
        Fountain.Telemetry.span(
          [:packages],
          %{conv_id: conv_id, commands: length(cmds)},
          fn ->
            publish_stage(conv_id, "packages", "started", %{commands: length(cmds)})

            result =
              Enum.reduce_while(cmds, :ok, fn cmd, _ ->
                # Retried: apt-get install -y and npm install -g are safe to
                # re-run. A non-zero exit comes back as {:ok, output, code} and
                # is handled below, not retried — only a failure to reach the
                # sandbox at all is.
                Retry.with_backoff(
                  fn ->
                    Sandbox.exec(handle, "bash", ["-lc", cmd],
                      env: sprite_env,
                      stderr_to_stdout: true,
                      timeout: 300_000
                    )
                  end,
                  label: "package install"
                )
                |> case do
                  {:ok, output, 0} ->
                    log_output(conv_id, "packages", output)
                    {:cont, :ok}

                  {:ok, output, code} ->
                    log_output(conv_id, "packages", output)
                    {:halt, {:error, {:packages, code, output}}}

                  {:error, reason} ->
                    {:halt, {:error, {:packages_unreachable, reason}}}
                end
              end)

            case result do
              :ok ->
                publish_stage(conv_id, "packages", "done")
                {:ok, %{outcome: :ok}}

              {:error, {:packages, code, _}} = err ->
                publish_stage(conv_id, "packages", "failed", %{exit_code: code})
                {err, %{outcome: :failed, exit_code: code}}

              {:error, reason} = err ->
                publish_stage(conv_id, "packages", "failed", %{reason: inspect(reason)})
                {err, %{outcome: :failed, reason: inspect(reason)}}
            end
          end
        )
    end
  end

  @doc false
  def build_package_commands(%{} = pkgs) do
    apt_cmds = build_apt_commands(Map.get(pkgs, "apt", []))
    npm_cmds = build_npm_commands(Map.get(pkgs, "npm", []))
    apt_cmds ++ npm_cmds
  end

  def build_package_commands(_), do: []

  @package_managers ~w(apt npm)

  @doc """
  The package managers `install_packages/4` acts on. An environment's
  `packages` map may carry other keys (the form used to offer pip, cargo, gem
  and go); they are stored and ignored — nothing installs them (#815).
  """
  def package_managers, do: @package_managers

  @doc false
  def build_apt_commands([]), do: []

  def build_apt_commands(list) when is_list(list) do
    quoted = list |> Enum.filter(&is_binary/1) |> Enum.map_join(" ", &shell_quote/1)

    if quoted == "",
      do: [],
      else: [
        "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq #{quoted}"
      ]
  end

  @doc false
  def build_npm_commands([]), do: []

  def build_npm_commands(list) when is_list(list) do
    quoted = list |> Enum.filter(&is_binary/1) |> Enum.map_join(" ", &shell_quote/1)
    if quoted == "", do: [], else: ["npm install -g --no-progress --silent #{quoted}"]
  end

  # ── network policy ────────────────────────────────────────────────────────

  @doc """
  Refuse a `limited` environment on a backend that cannot enforce one, before
  anything is provisioned.

  Not every provider can hold egress. `Fountain.Sandbox.Runner` answers
  `{:error, :not_supported}` and leaves `:network_policy` out of its
  `capabilities/0`; Sprites, E2B and Daytona all advertise it. The pairing has
  always failed closed — `apply_network_policy/3` turns the `:not_supported`
  into `{:error, {:network_policy, :not_supported}}` and the cold-provision
  `with` aborts — so a `limited` environment has never run unrestricted.

  What was missing is *when* and *why* the operator finds out. The failure
  arrived several steps into provisioning, after a sandbox had been created,
  wearing the same shape as a transport error. This check runs before the
  sandbox exists and names the cause: a `network` / `failed` stage event whose
  reason is `backend_lacks_network_policy`.

  The provider is per agent since ADR 0018, so an `Environment` cannot answer
  this on its own — one environment is reachable from agents on different
  backends. Both facts are only known here, at launch (#935, #627).
  """
  @spec check_network_policy_support(atom(), Environment.t() | nil, String.t()) ::
          :ok | {:error, {:network_policy, :unsupported_by_backend}}
  def check_network_policy_support(_provider, nil, _conv_id), do: :ok

  def check_network_policy_support(provider, %Environment{networking_type: "limited"}, conv_id) do
    if Sandbox.supports?(provider, :network_policy) do
      :ok
    else
      publish_stage(conv_id, "network", "failed", %{
        type: "limited",
        provider: to_string(provider),
        reason: "backend_lacks_network_policy"
      })

      {:error, {:network_policy, :unsupported_by_backend}}
    end
  end

  def check_network_policy_support(_provider, _env, _conv_id), do: :ok

  @doc """
  Refuse a brokered pairing that cannot be enforced, before a sandbox exists
  (ADR 0019 gate 1a). Same shape and reason as `check_network_policy_support/3`.

  Three refusals, each by name: a `limited` environment (its `allowed_hosts`
  become broker rules in gate 2, and a floor that ignored them would be a
  policy the author did not write); a provider with no `:network_policy`,
  unless `BROKER_ALLOW_UNENFORCED` says a development box may run advisory;
  and a broker that does not answer `/health`, so an outage is reported as
  one rather than as the install failure it would otherwise wear (§6).
  """
  @spec check_broker_support(boolean(), atom(), Environment.t() | nil, String.t()) ::
          :ok | {:error, {:broker, atom()} | {:broker, :unreachable, term()}}
  def check_broker_support(false, _provider, _env, _conv_id), do: :ok

  def check_broker_support(true, provider, env, conv_id) do
    cond do
      match?(%Environment{networking_type: "limited"}, env) ->
        publish_stage(conv_id, "broker", "failed", %{reason: "limited_environment_unsupported"})
        {:error, {:broker, :limited_environment_unsupported}}

      not Sandbox.supports?(provider, :network_policy) and not Fountain.Broker.allow_unenforced?() ->
        publish_stage(conv_id, "broker", "failed", %{
          provider: to_string(provider),
          reason: "backend_lacks_network_policy"
        })

        {:error, {:broker, :backend_lacks_network_policy}}

      true ->
        case Fountain.Broker.preflight() do
          :ok ->
            :ok

          {:error, {:broker, :unreachable, detail}} = err ->
            publish_stage(conv_id, "broker", "failed", %{
              reason: "broker_unreachable",
              detail: inspect(detail)
            })

            err
        end
    end
  end

  @doc """
  The network floor of a brokered sandbox: the broker's host is the one
  domain it may reach, whatever the environment's `networking_type` says
  (ADR 0019 §2). On a provider without `:network_policy` this is skipped,
  which `check_broker_support/4` only allows under `BROKER_ALLOW_UNENFORCED`.
  """
  @spec apply_broker_floor(Handle.t(), String.t()) :: :ok | {:error, term()}
  def apply_broker_floor(handle, conv_id) do
    host = Fountain.Broker.proxy_host()

    if Sandbox.supports?(handle, :network_policy) do
      Fountain.Telemetry.span(
        [:network_policy],
        %{conv_id: conv_id, hosts: 1},
        fn ->
          publish_stage(conv_id, "network", "started", %{type: "broker", hosts: 1})

          case Retry.with_backoff(
                 fn -> Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: [host]}) end,
                 label: "broker network floor"
               ) do
            :ok ->
              publish_stage(conv_id, "network", "done", %{type: "broker"})
              {:ok, %{outcome: :ok}}

            {:error, reason} ->
              publish_stage(conv_id, "network", "failed", %{reason: inspect(reason)})
              {{:error, {:network_policy, reason}}, %{outcome: :failed, reason: inspect(reason)}}
          end
        end
      )
    else
      publish_stage(conv_id, "network", "done", %{type: "broker", enforced: false})
      :ok
    end
  end

  @doc """
  Put the broker's root CA in the sandbox's operating-system trust store.
  Gate 0 found that one `update-ca-certificates` satisfies curl, git and npm
  at once, where per-tool variables each fail in their own way. Node is the
  exception and reads `NODE_EXTRA_CA_CERTS`, which `Fountain.Broker.sandbox_env/1`
  points at the same file.
  """
  @spec install_broker_ca(Handle.t(), String.t()) :: :ok | {:error, term()}
  def install_broker_ca(handle, conv_id) do
    path = Fountain.Broker.ca_path()

    with {:ok, pem} <- Fountain.Broker.ca_pem(),
         :ok <-
           Retry.with_backoff(fn -> Sandbox.write_file(handle, path, pem, mode: 0o644) end,
             label: "broker CA write"
           ) do
      case Sandbox.exec(handle, "bash", ["-lc", "sudo update-ca-certificates"],
             stderr_to_stdout: true,
             timeout: 60_000
           ) do
        {:ok, _out, 0} ->
          :ok

        {:ok, out, code} ->
          publish_stage(conv_id, "broker", "failed", %{reason: "ca_install_exit", exit_code: code})
          {:error, {:broker, :ca_install_exit, code, String.slice(to_string(out), 0, 500)}}

        {:error, reason} ->
          publish_stage(conv_id, "broker", "failed", %{reason: "ca_install_unreachable"})
          {:error, {:broker, :ca_install, reason}}
      end
    else
      {:error, reason} = err ->
        publish_stage(conv_id, "broker", "failed", %{reason: inspect(reason)})
        err
    end
  end

  @doc """
  Apply the env's networking config to the sandbox. `unrestricted` is a
  no-op (sandboxes are open by default). `limited` builds an allowlist from
  `networking_config.allowed_hosts: [...]` and applies it as a default-deny
  `Fountain.Sandbox.NetworkPolicy` — an empty/absent allowlist therefore
  denies all egress. Translating that intent into provider mechanics
  (including Sprites' rules-empty-means-allow-all quirk) is the adapter's
  job.
  """
  def apply_network_policy(_handle, nil, _conv_id), do: :ok

  def apply_network_policy(_handle, %Environment{networking_type: "unrestricted"}, _conv_id),
    do: :ok

  def apply_network_policy(handle, %Environment{networking_type: "limited"} = env, conv_id) do
    hosts = get_in(env.networking_config, ["allowed_hosts"]) || []

    Fountain.Telemetry.span(
      [:network_policy],
      %{conv_id: conv_id, hosts: length(hosts)},
      fn ->
        publish_stage(conv_id, "network", "started", %{type: "limited", hosts: length(hosts)})

        case Retry.with_backoff(
               fn -> Sandbox.apply_network_policy(handle, %NetworkPolicy{allow: hosts}) end,
               label: "network policy"
             ) do
          :ok ->
            publish_stage(conv_id, "network", "done")
            {:ok, %{outcome: :ok}}

          {:error, reason} ->
            publish_stage(conv_id, "network", "failed", %{reason: inspect(reason)})
            {{:error, {:network_policy, reason}}, %{outcome: :failed, reason: inspect(reason)}}
        end
      end
    )
  end

  def apply_network_policy(_handle, _env, _conv_id), do: :ok

  # ── git clone ─────────────────────────────────────────────────────────────

  @doc """
  Clone every repository declared on the env into the sandbox at its
  `mount_path`. HTTPS only, x-access-token auth via the env secret named
  by `secret_key`. Returns `:ok` or `{:error, ...}` on first failure.
  """
  def clone_repositories(_handle, nil, _secrets, _sprite_env, _conv_id), do: :ok

  def clone_repositories(
        _handle,
        %Environment{repositories: repos},
        _secrets,
        _sprite_env,
        _conv_id
      )
      when repos in [nil, []],
      do: :ok

  def clone_repositories(handle, %Environment{repositories: repos}, secrets, sprite_env, conv_id) do
    Fountain.Telemetry.span(
      [:clone_repositories],
      %{conv_id: conv_id, count: length(repos)},
      fn ->
        publish_stage(conv_id, "clone", "started", %{count: length(repos)})

        result =
          Enum.reduce_while(repos, :ok, fn repo, _ ->
            case clone_one(handle, repo, secrets, sprite_env, conv_id) do
              :ok -> {:cont, :ok}
              err -> {:halt, err}
            end
          end)

        case result do
          :ok ->
            publish_stage(conv_id, "clone", "done")
            {:ok, %{outcome: :ok}}

          {:error, reason} = err ->
            publish_stage(conv_id, "clone", "failed", %{reason: inspect(reason)})
            {err, %{outcome: :failed, reason: inspect(reason)}}
        end
      end
    )
  end

  # https + token is the only clone mechanism. An SSH path (key-from-secret,
  # pinned host keys) existed here fully implemented but was unreachable —
  # validation has required https:// since the schema was written, and nobody
  # ever got an ssh repo past it. Deleted rather than enabled (#228): the use
  # case is covered by token auth, and enabling it would first have required
  # establishing that limited networking permits SSH at all. The implementation
  # lives in git history if real demand ever shows up.
  defp clone_one(handle, %{"url" => url} = repo, secrets, sprite_env, conv_id) do
    if is_binary(url) and String.starts_with?(url, "https://") do
      clone_https(handle, repo, secrets, sprite_env, conv_id)
    else
      {:error, {:clone_unsupported_url, url}}
    end
  end

  defp clone_one(_, repo, _, _, _), do: {:error, {:clone_invalid_spec, repo}}

  # `env:` is passed for the same reason every other step passes it: a
  # brokered clone reaches GitHub only through `HTTPS_PROXY`, and git reads
  # that from its environment. It was the one step that ran bare.
  defp clone_https(
         handle,
         %{"url" => url, "mount_path" => mount} = repo,
         secrets,
         sprite_env,
         conv_id
       ) do
    auth_url = inject_token(url, repo["secret_key"], secrets)

    cmd =
      git_env_prefix() <>
        "mkdir -p #{shell_quote(Path.dirname(mount))} && " <>
        "git clone --depth 50 #{branch_arg(repo)}#{shell_quote(auth_url)} #{shell_quote(mount)}"

    # Not retried: a clone into a half-written directory is not idempotent.
    case Sandbox.exec(handle, "bash", ["-lc", cmd],
           env: sprite_env,
           stderr_to_stdout: true,
           timeout: 600_000
         ) do
      {:ok, output, code} ->
        log_output(conv_id, "clone", scrub_token(output))
        if code == 0, do: :ok, else: {:error, {:clone, url, code}}

      {:error, reason} ->
        {:error, {:clone_unreachable, url, reason}}
    end
  end

  # The sprite user can't read `/home/sprite/.config/git/ignore` (parent
  # dir's perms reject the access(2) check even though most writes go
  # through), so git emits "warning: unable to access ..." on every
  # clone. Pin XDG_CONFIG_HOME to /tmp where git can actually stat the
  # path; missing files are fine (git treats absent global ignore as
  # "no global ignore"), it's the EACCES that produces the warning.
  defp git_env_prefix do
    "export XDG_CONFIG_HOME=/tmp; "
  end

  defp branch_arg(repo) do
    case repo["ref"] do
      ref when is_binary(ref) and ref != "" -> "-b #{shell_quote(ref)} "
      _ -> ""
    end
  end

  @doc false
  def inject_token(url, nil, _), do: url
  def inject_token(url, "", _), do: url

  def inject_token(url, key, secrets) when is_map(secrets) do
    case Map.get(secrets, key) do
      nil -> url
      "" -> url
      token -> rewrite_https_with_token(url, token)
    end
  end

  def inject_token(url, _, _), do: url

  @doc false
  def rewrite_https_with_token("https://" <> rest, token) do
    "https://x-access-token:#{token}@" <> rest
  end

  def rewrite_https_with_token(url, _), do: url

  # Avoid leaking the token into log_events when git's clone output echoes
  # the URL back (it sometimes does on auth errors).
  @doc false
  def scrub_token(s) when is_binary(s),
    do: Regex.replace(~r{https://x-access-token:[^@]+@}, s, "https://x-access-token:***@")

  def scrub_token(s), do: s

  # ── helpers ───────────────────────────────────────────────────────────────

  @doc false
  def shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp publish_stage(conv_id, stage, status, meta \\ %{}) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end

  # Stamp the output with the stage that was active when it was emitted
  # so the LiveView (and any API consumer) can group output under its
  # owning stage without inferring it from event interleaving.
  defp log_output(conv_id, stage, output) when is_binary(output) and output != "" do
    Conversations.log!(%{
      conversation_id: conv_id,
      kind: "output",
      stream: "stdout",
      stage: stage,
      data: output
    })
    |> tap(fn ev ->
      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, ev})
    end)
  end

  defp log_output(_conv_id, _stage, _), do: :ok
end
