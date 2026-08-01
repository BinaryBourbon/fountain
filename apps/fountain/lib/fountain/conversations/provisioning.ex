defmodule Fountain.Conversations.Provisioning do
  @moduledoc """
  Provisioning steps that run inside a freshly-created sprite, before the
  runtime CLI is spawned. Each step publishes its own stage events so the
  UI/SSE clients can show progress.

  Order in `ConversationServer.handle_continue(:provision)`:
    1. mount skills (inline writes + skills.sh github installs — github
       installs need network and run before the policy lockdown)
    2. `install_packages/4` (apt/npm — needs unrestricted network; must
       run before the policy lockdown so apt can reach package repos)
    3. `apply_network_policy/3` (sprite API call — fast)
    4. `clone_repositories/4` (git clone — slow)
    5. user's `setup_script` (whatever they supplied)
    6. write runtime-specific config (e.g. claude `~/.claude.json`)

  Each step is a no-op when the corresponding field is empty, so legacy
  environments with bare config (just a name) provision instantly.
  """

  alias Fountain.Conversations
  alias Fountain.Environments.Environment

  require Logger

  @env_file "/home/sprite/.env"

  @doc """
  Write the merged sprite env (default + callback + env_vars + secrets)
  to `/home/sprite/.env` so a `setup_script` that does `source .env`
  picks up the variables. Mirrors the legacy AoD's `env_file.py`.

  The file is `chmod 600` after the write so other sprite users (if any)
  can't read tokens.
  """
  def write_env_file(_sprite, sprite_env) when sprite_env in [nil, []], do: :ok

  def write_env_file(sprite, sprite_env) do
    body = render_env_file(sprite_env)
    fs = Sprites.filesystem(sprite, "/")

    case Sprites.Filesystem.write(fs, @env_file, body) do
      :ok ->
        # Ignore chmod errors — we still wrote the file. Defense in depth,
        # not a hard requirement.
        Sprites.cmd(sprite, "chmod", ["600", @env_file], timeout: 5_000)
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
  Create a sprites.dev checkpoint of the fully-provisioned sprite. The
  checkpoint id is persisted onto the environment row so subsequent
  conversations can warm-start from it instead of redoing
  packages/repos/setup_script.

  Best-effort — failures are logged and don't block the conversation.
  Caller typically wraps in `Task.start/1` so the user's first turn
  isn't gated on the checkpoint upload.
  """
  def create_checkpoint(_sprite, nil), do: {:error, :no_env}

  def create_checkpoint(sprite, %Environment{} = env) do
    Fountain.Telemetry.span([:checkpoint, :create], %{env_id: env.id}, fn ->
      case Sprites.create_checkpoint(sprite, comment: "aod env #{env.name}") do
        {:ok, stream} ->
          checkpoint_id =
            stream
            |> Enum.reduce(nil, fn msg, acc -> extract_checkpoint_id(msg) || acc end)

          if is_binary(checkpoint_id) and checkpoint_id != "" do
            {:ok, _} =
              Fountain.Environments.update_environment(env, %{
                "checkpoint_id" => checkpoint_id
              })

            {{:ok, checkpoint_id}, %{outcome: :ok, checkpoint_id: checkpoint_id}}
          else
            Logger.warning("checkpoint create stream finished without a checkpoint_id")
            {{:error, :no_checkpoint_id}, %{outcome: :no_id}}
          end

        {:error, reason} ->
          Logger.warning("checkpoint create failed for env #{env.name}: #{inspect(reason)}")
          {{:error, reason}, %{outcome: :failed, reason: inspect(reason)}}
      end
    end)
  end

  defp extract_checkpoint_id(%{"checkpoint_id" => id}) when is_binary(id), do: id
  defp extract_checkpoint_id(%{checkpoint_id: id}) when is_binary(id), do: id
  defp extract_checkpoint_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_checkpoint_id(_), do: nil

  @doc """
  Restore a sprite from a saved checkpoint. Drains the stream so the
  operation is fully complete on return. Returns `:ok` on success or
  `{:error, reason}` if the checkpoint is gone / restore failed; the
  caller should clear `env.checkpoint_id` and fall back to fresh
  provisioning.
  """
  def restore_checkpoint(_sprite, nil), do: {:error, :no_checkpoint}
  def restore_checkpoint(_sprite, ""), do: {:error, :no_checkpoint}

  def restore_checkpoint(sprite, checkpoint_id) when is_binary(checkpoint_id) do
    Fountain.Telemetry.span(
      [:checkpoint, :restore],
      %{checkpoint_id: checkpoint_id},
      fn ->
        case Sprites.restore_checkpoint(sprite, checkpoint_id) do
          {:ok, stream} ->
            try do
              Enum.each(stream, fn _ -> :ok end)
              {:ok, %{outcome: :ok}}
            rescue
              e ->
                Logger.warning("checkpoint restore stream raised: #{inspect(e)}")
                {{:error, :stream_error}, %{outcome: :stream_error}}
            end

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
  {step, exit_code, output}}` on first failure (sprite kept alive so the
  caller can decide whether to destroy).
  """
  def install_packages(_sprite, nil, _sprite_env, _conv_id), do: :ok

  def install_packages(sprite, %Environment{} = env, sprite_env, conv_id) do
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
                {output, code} =
                  Sprites.cmd(sprite, "bash", ["-lc", cmd],
                    env: sprite_env,
                    stderr_to_stdout: true,
                    timeout: 300_000
                  )

                log_output(conv_id, "packages", output)

                if code == 0,
                  do: {:cont, :ok},
                  else: {:halt, {:error, {:packages, code, output}}}
              end)

            case result do
              :ok ->
                publish_stage(conv_id, "packages", "done")
                {:ok, %{outcome: :ok}}

              {:error, {:packages, code, _}} = err ->
                publish_stage(conv_id, "packages", "failed", %{exit_code: code})
                {err, %{outcome: :failed, exit_code: code}}
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
  Apply the env's networking config to the sprite. `unrestricted` is a
  no-op (sprites are open by default). `limited` builds an allowlist from
  `networking_config.allowed_hosts: [...]`. Sprites treats a policy with no
  rules as "no enforcement" (allow-all), so an empty/absent allowlist is
  translated into an explicit deny-all rule rather than a bare `rules: []`
  — otherwise `limited` with nothing allowed would silently open full
  egress instead of denying it.
  """
  def apply_network_policy(_sprite, nil, _conv_id), do: :ok

  def apply_network_policy(_sprite, %Environment{networking_type: "unrestricted"}, _conv_id),
    do: :ok

  def apply_network_policy(sprite, %Environment{networking_type: "limited"} = env, conv_id) do
    hosts = get_in(env.networking_config, ["allowed_hosts"]) || []

    Fountain.Telemetry.span(
      [:network_policy],
      %{conv_id: conv_id, hosts: length(hosts)},
      fn ->
        rules = network_policy_rules(hosts)
        publish_stage(conv_id, "network", "started", %{type: "limited", hosts: length(hosts)})

        case Sprites.update_network_policy(sprite, %Sprites.Policy{rules: rules}) do
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

  def apply_network_policy(_sprite, _env, _conv_id), do: :ok

  # An empty allowlist must still deny by default. Sending Sprites a bare
  # `rules: []` is interpreted as "no enforcement" (allow-all) on their
  # side, so `limited` with nothing allowed would otherwise fail open.
  # The deny rule stands alone — no `include: "defaults"` — since pulling
  # in Sprites' own default allowances would defeat the deny-all.
  defp network_policy_rules([]), do: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]

  defp network_policy_rules(hosts),
    do: Enum.map(hosts, &%Sprites.Policy.Rule{domain: &1, action: "allow"})

  # ── git clone ─────────────────────────────────────────────────────────────

  @doc """
  Clone every repository declared on the env into the sprite at its
  `mount_path`. HTTPS only, x-access-token auth via the env secret named
  by `secret_key`. Returns `:ok` or `{:error, ...}` on first failure.
  """
  def clone_repositories(_sprite, nil, _secrets, _conv_id), do: :ok

  def clone_repositories(_sprite, %Environment{repositories: repos}, _secrets, _conv_id)
      when repos in [nil, []],
      do: :ok

  def clone_repositories(sprite, %Environment{repositories: repos}, secrets, conv_id) do
    Fountain.Telemetry.span(
      [:clone_repositories],
      %{conv_id: conv_id, count: length(repos)},
      fn ->
        publish_stage(conv_id, "clone", "started", %{count: length(repos)})

        result =
          Enum.reduce_while(repos, :ok, fn repo, _ ->
            case clone_one(sprite, repo, secrets, conv_id) do
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

  defp clone_one(sprite, %{"url" => url} = repo, secrets, conv_id) do
    cond do
      ssh_url?(url) -> clone_ssh(sprite, repo, secrets, conv_id)
      String.starts_with?(url, "https://") -> clone_https(sprite, repo, secrets, conv_id)
      true -> {:error, {:clone_unsupported_url, url}}
    end
  end

  defp clone_one(_, repo, _, _), do: {:error, {:clone_invalid_spec, repo}}

  defp clone_https(sprite, %{"url" => url, "mount_path" => mount} = repo, secrets, conv_id) do
    auth_url = inject_token(url, repo["secret_key"], secrets)

    cmd =
      git_env_prefix() <>
        "mkdir -p #{shell_quote(Path.dirname(mount))} && " <>
        "git clone --depth 50 #{branch_arg(repo)}#{shell_quote(auth_url)} #{shell_quote(mount)}"

    {output, code} =
      Sprites.cmd(sprite, "bash", ["-lc", cmd],
        stderr_to_stdout: true,
        timeout: 600_000
      )

    log_output(conv_id, "clone", scrub_token(output))

    if code == 0, do: :ok, else: {:error, {:clone, url, code}}
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

  # Host keys for the common forges, so an SSH clone verifies who it is talking
  # to. Every one of these was checked against the provider's own published
  # fingerprints fetched over TLS — ssh-keyscan alone is the very channel this
  # is meant to protect against, so scanning and pinning the result would be
  # circular.
  #
  # Providers do rotate these (GitHub replaced its RSA key in 2023). A rotation
  # makes clones from that host fail closed rather than silently succeed against
  # an unknown key, which is the intended direction.
  @known_hosts [
                 "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
                 "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=",
                 "github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=",
                 "gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf",
                 "gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2bNKTBSpIYDEGk9KxsGh3mySTRgMtXL583qmBpzeQ+jqCMRgBqB98u3z++J1sKlXHWfM9dyhSevkMwSbhoR8XIq/U0tCNyokEi/ueaBMCvbcTHhO7FcwzY92WK4Yt0aGROY5qX2UKSeOvuP4D6TPqKF1onrSzH9bx9XUf2lEdWT/ia1NEKjunUqu1xOB/StKDHMoX4/OKyIzuS0q/T1zOATthvasJFoPrAjkohTyaDUz2LN5JoH839hViyEG82yB+MjcFV5MU3N1l1QL3cVUCh93xSaua1N85qivl+siMkPGbO5xR/En4iEY6K2XPASUEMaieWVNTRCtJ4S8H+9",
                 "bitbucket.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO",
                 "bitbucket.org ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDQeJzhupRu0u0cdegZIa8e86EG2qOCsIsD1Xw0xSeiPDlCr7kq97NLmMbpKTX6Esc30NuoqEEHCuc7yWtwp8dI76EEEB1VqY9QJq6vk+aySyboD5QF61I/1WeTwu+deCbgKMGbUijeXhtfbxSxm6JwGrXrhBdofTsbKRUsrN1WoNgUa8uqN1Vx6WAJw1JHPhglEGGHea6QICwJOAr/6mrui/oB7pkaWKHj3z7d1IC4KWLtY47elvjbaTlkN04Kc/5LFEirorGYVbt15kAUlqGM65pk6ZBxtaO3+30LVlORZkxOh+LKL/BvbZ/iRNhItLqNyieoQj/uh/7Iv4uyH/cV/0b4WDSd3DptigWq84lJubb9t/DnZlrJazxyDCulTmKdOR7vs9gMTo+uoIrPSb8ScTtvw65+odKAlBj59dhnVp9zd7QUojOpXlL62Aw56U4oO+FALuevvMjiWeavKhJqlR7i5n9srYcrNV7ttmDw7kf/97P5zauIhxcjX+xHv4M="
               ]
               |> Enum.join("\n")
               |> Kernel.<>("\n")

  # SSH clone via key-from-secret. The private key is written to a short-lived
  # path inside the sprite, GIT_SSH_COMMAND uses it for this clone, and the file
  # is removed on exit.
  defp clone_ssh(sprite, %{"url" => url, "mount_path" => mount} = repo, secrets, conv_id) do
    case fetch_secret(repo["ssh_key_secret"], secrets) do
      {:ok, key} ->
        unique = :erlang.unique_integer([:positive])
        key_path = "/tmp/aod_ssh_#{unique}"
        hosts_path = "/tmp/aod_known_hosts_#{unique}"

        # Written as files rather than heredoc'd into the command. The heredoc
        # used a fixed sentinel, so a key containing a line equal to it
        # terminated the heredoc early and the remainder of the key ran as
        # shell — an arbitrary-write primitive into the provisioning command.
        fs = Sprites.filesystem(sprite, "/")

        with :ok <- Sprites.Filesystem.write(fs, key_path, key),
             :ok <- Sprites.Filesystem.write(fs, hosts_path, @known_hosts) do
          # Cleanup via trap rather than `rc=$?; rm ...`: with `set -e` a failed
          # clone exits the shell immediately, so the trailing rm never ran and
          # the private key stayed on the sprite for the rest of its life.
          cmd =
            ~s|set -e; |
            |> Kernel.<>(
              ~s|trap 'rm -f #{shell_quote(key_path)} #{shell_quote(hosts_path)}' EXIT; |
            )
            |> Kernel.<>(git_env_prefix())
            |> Kernel.<>(~s|chmod 600 #{shell_quote(key_path)}; |)
            |> Kernel.<>(~s|mkdir -p #{shell_quote(Path.dirname(mount))}; |)
            # accept-new rather than no: a pinned host is verified and a
            # mismatch fails, while an unrecognised host (someone's self-hosted
            # git server) is still usable. `no` disabled the check entirely,
            # including for a host whose key had changed under us.
            |> Kernel.<>(
              ~s|GIT_SSH_COMMAND='ssh -i #{key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=#{hosts_path}' |
            )
            |> Kernel.<>(
              ~s|git clone --depth 50 #{branch_arg(repo)}#{shell_quote(url)} #{shell_quote(mount)}|
            )

          run_ssh_clone(sprite, cmd, url, conv_id)
        else
          {:error, reason} -> {:error, {:clone_ssh_write, reason}}
        end

      {:error, reason} ->
        {:error, {:clone_ssh_secret, reason}}
    end
  end

  defp run_ssh_clone(sprite, cmd, url, conv_id) do
    {output, code} =
      Sprites.cmd(sprite, "bash", ["-lc", cmd],
        stderr_to_stdout: true,
        timeout: 600_000
      )

    # The HTTPS path scrubbed and this one did not, which is exactly the kind of
    # divergence the registry-based redaction in Conversations.log!/1 is there
    # to make impossible.
    log_output(conv_id, "clone", scrub_token(output))

    if code == 0, do: :ok, else: {:error, {:clone, url, code}}
  end

  @doc false
  def ssh_url?(url) when is_binary(url) do
    String.starts_with?(url, "ssh://") or
      Regex.match?(~r/^[^@\s]+@[^:\s]+:/, url)
  end

  def ssh_url?(_), do: false

  defp branch_arg(repo) do
    case repo["ref"] do
      ref when is_binary(ref) and ref != "" -> "-b #{shell_quote(ref)} "
      _ -> ""
    end
  end

  defp fetch_secret(nil, _), do: {:error, :no_secret_key}
  defp fetch_secret("", _), do: {:error, :no_secret_key}

  defp fetch_secret(key, secrets) when is_map(secrets) do
    case Map.get(secrets, key) do
      nil -> {:error, {:missing_secret, key}}
      "" -> {:error, {:empty_secret, key}}
      v -> {:ok, v}
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

  defp publish_stage(conv_id, stage, state, meta \\ %{}) do
    Conversations.log!(%{
      conversation_id: conv_id,
      kind: "stage",
      stage: stage,
      state: state,
      data: Jason.encode!(meta)
    })
    |> tap(fn ev ->
      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, ev})
    end)
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
