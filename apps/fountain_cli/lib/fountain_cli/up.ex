defmodule FountainCli.Up do
  @moduledoc """
  Deploy AoD into a Sprite, or upgrade an existing deployment in place.

  Invoked from two places:
    * `mix aod.up` (Mix task wrapper) — runs from a project checkout.
    * `./aod up` (the released binary's CLI mode) — runs anywhere,
      no Erlang install or repo needed.

  Both paths land here.

  Reads `SPRITES_TOKEN` from env (or a `.env` in the current dir).

  ## Binary source

  Pushes the Linux Burrito binary to the sprite. Resolution order:

    1. Local build at `burrito_out/aod_linux` — used if it exists
       (ideal for dev iteration: `MIX_ENV=prod mix release`).
    2. Otherwise, downloads the binary from the project's GitHub
       release matching the current build version. Cached under
       `~/.cache/aod/releases/<tag>/` (or `$XDG_CACHE_HOME/aod/...`).

  Override the release with `--release vX.Y.Z` (or just `0.1.0`).

  ## Deploy (fresh)

  Without `--name`, or with a `--name` that doesn't exist yet at
  sprites.dev, runs the full deploy: provision a sprite, generate
  fresh secrets, push the binary, register the service, poll
  `/health`, print the URL + admin token.

  ## Upgrade (in place)

  When `--name` matches an existing sprite, runs the upgrade flow
  instead: recover the secrets we wrote into `/opt/aod/start.sh` on
  the original deploy, push the new binary on top of the old one,
  rewrite `start.sh` (env shape may have evolved between releases),
  recreate the `sprite-env` service so it picks up the new binary,
  poll `/health`. The SQLite DB at `/opt/aod/data/aod.db` and the
  encryption key are preserved.
  """

  # Captured at compile time so the released binary embeds whatever
  # version it was built at. Mix isn't available at runtime in a
  # release.
  @app_version Mix.Project.config()[:version]

  @local_binary_path "burrito_out/aod_server_linux"
  @release_asset_name "aod-server-linux-x86_64"
  @github_repo "jhgaylor/aod-ex"
  @remote_binary "/opt/aod/aod"
  @remote_start_sh "/opt/aod/start.sh"
  @remote_db "/opt/aod/data/aod.db"
  @port 4000

  @doc """
  Entry point. Parses args (passed through from either the Mix task
  wrapper or the FountainCli main dispatcher) and runs the deploy/upgrade.
  """
  def dispatch(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [name: :string, release: :string]
      )

    Application.ensure_all_started(:req)
    Application.ensure_all_started(:gun)
    Application.ensure_all_started(:sprites)

    token =
      System.get_env("SPRITES_TOKEN") || load_dot_env("SPRITES_TOKEN") ||
        FountainCli.die("SPRITES_TOKEN not set")

    client = Sprites.new(token)

    case opts[:name] do
      nil ->
        binary_path = resolve_binary_path(opts[:release])
        deploy(client, "aod-host-#{:os.system_time(:second)}", binary_path, token)

      name ->
        binary_path = resolve_binary_path(opts[:release])

        case Sprites.get_sprite(client, name) do
          {:ok, _info} ->
            upgrade(client, name, binary_path, token)

          {:error, {:not_found, _}} ->
            deploy(client, name, binary_path, token)

          {:error, reason} ->
            FountainCli.die("could not check sprite '#{name}': #{inspect(reason)}")
        end
    end
  end

  # ── binary resolution ────────────────────────────────────────────
  #
  # Returns either:
  #   {:local, path}        — operator's local build at burrito_out/...
  #                            push via fs/write (size-limited by sprites.dev).
  #   {:release_url, url}   — short-lived signed URL to a GitHub release asset.
  #                            sprite curls it directly — avoids the 22 MB+
  #                            body limit on /fs/write entirely.

  defp resolve_binary_path(nil) do
    cond do
      File.exists?(@local_binary_path) ->
        info("using local build: #{@local_binary_path}")
        {:local, Path.expand(@local_binary_path)}

      true ->
        tag = "v" <> @app_version

        info(
          "no local build found at #{@local_binary_path}; falling back to GitHub release #{tag}"
        )

        {:release_url, resolve_release_signed_url(tag)}
    end
  end

  defp resolve_binary_path(release_arg) when is_binary(release_arg) do
    tag = if String.starts_with?(release_arg, "v"), do: release_arg, else: "v" <> release_arg
    info("using GitHub release #{tag} (--release override)")
    {:release_url, resolve_release_signed_url(tag)}
  end

  # Resolve the release asset's signed download URL (S3-backed,
  # short-lived ~5min) without actually downloading. The sprite uses
  # this URL via `curl` directly — much faster than streaming the
  # binary through the operator's HTTP client and back, and the
  # signed URL doesn't need GitHub auth (GitHub embedded the auth
  # in the query string).
  defp resolve_release_signed_url(tag) do
    asset_id = lookup_asset_id(tag)

    url = "https://api.github.com/repos/#{@github_repo}/releases/assets/#{asset_id}"

    headers = [
      {"accept", "application/octet-stream"},
      {"x-github-api-version", "2022-11-28"}
    ]

    # `redirect: false` — capture the 302 to objects.githubusercontent.com
    # rather than following it (we don't want to download).
    case Req.get(url, headers: headers, redirect: false, receive_timeout: 30_000) do
      {:ok, %{status: 302} = resp} ->
        case Req.Response.get_header(resp, "location") do
          [signed_url | _] ->
            info("resolved signed asset URL (#{tag} / #{@release_asset_name})")
            signed_url

          [] ->
            FountainCli.die("release asset endpoint returned 302 but no Location header")
        end

      {:ok, %{status: status}} ->
        FountainCli.die("could not resolve signed URL for #{tag}: GET #{url} returned HTTP #{status}")

      {:error, reason} ->
        FountainCli.die("could not resolve signed URL for #{tag}: #{inspect(reason)}")
    end
  end

  defp lookup_asset_id(tag) do
    url = "https://api.github.com/repos/#{@github_repo}/releases/tags/#{tag}"

    headers = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case Req.get(url, headers: headers, redirect: true, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"assets" => assets}}} ->
        case Enum.find(assets, &(&1["name"] == @release_asset_name)) do
          %{"id" => id} ->
            id

          nil ->
            available = assets |> Enum.map(& &1["name"]) |> Enum.join(", ")

            FountainCli.die(
              "release #{tag} has no asset named `#{@release_asset_name}` " <>
                "(found: #{available})"
            )
        end

      {:ok, %{status: status}} ->
        FountainCli.die(
          "could not look up release #{tag}: GET #{url} returned HTTP #{status} " <>
            "(does the tag exist with an `#{@release_asset_name}` asset?)"
        )

      {:error, reason} ->
        FountainCli.die("could not look up release #{tag}: #{inspect(reason)}")
    end
  end

  # ── deploy ───────────────────────────────────────────────────────

  defp deploy(client, name, binary_source, sprites_token) do
    info("provisioning sprite '#{name}'...")
    {:ok, sprite} = Sprites.create(client, name)

    info("flipping URL auth to public...")
    :ok = Sprites.update_url_settings(sprite, %{auth: "public"})

    info("looking up public hostname...")
    {:ok, sprite_info} = Sprites.get_sprite(client, name)
    public_url = extract_public_url(sprite_info, @port) || raise("no public URL on sprite")
    info("public url: #{public_url}")

    push_binary(sprite, binary_source)

    info("creating data dir...")
    {_, 0} = Sprites.cmd(sprite, "mkdir", ["-p", "/opt/aod/data"])

    secrets = %{
      admin_token: random_hex(24),
      secrets_key: random_url64(32),
      secret_key_base: random_hex(64)
    }

    env = build_env(secrets, public_url, sprites_token)

    info("writing #{@remote_start_sh} wrapper...")
    fs = Sprites.filesystem(sprite, "/")
    :ok = Sprites.Filesystem.write(fs, @remote_start_sh, start_script(env), mode: 0o755)

    info("registering service via sprite-env (survives hibernation)...")
    {_, _} = Sprites.cmd(sprite, "/.sprite/bin/sprite-env", ["services", "delete", "aod"])

    {out, code} =
      Sprites.cmd(
        sprite,
        "/.sprite/bin/sprite-env",
        [
          "services",
          "create",
          "aod",
          "--cmd",
          @remote_start_sh,
          "--http-port",
          Integer.to_string(@port),
          "--no-stream"
        ],
        timeout: 30_000,
        stderr_to_stdout: true
      )

    if code != 0, do: raise("sprite-env services create failed (code #{code}):\n#{out}")
    info("service registered: #{String.trim(out)}")

    info("polling /health (will auto-start service on first hit)...")
    wait_for_health(public_url)

    IO.puts("""

    ============================================================
    AoD is live!

      URL:           #{public_url}
      ADMIN_TOKEN:   #{secrets.admin_token}
      Sprite name:   #{name}

    Login at the URL with the ADMIN_TOKEN above.

    Tear down later with:
      aod down #{name}
    ============================================================
    """)
  end

  # ── binary push ──────────────────────────────────────────────────
  #
  # Two paths for getting the 21+ MB server binary into the sprite:
  #
  #   {:release_url, signed_url}
  #     Sprite-side `curl` from a short-lived signed S3 URL we
  #     resolved on the operator side. No huge body proxied through
  #     the operator's HTTP client; the sprite pulls directly. This
  #     is the common case (operators don't usually have a local
  #     build).
  #
  #   {:local, path}
  #     fs/write upload from operator → sprite. Hits sprites.dev's
  #     ~20 MB body limit on the fs/write endpoint, so this only
  #     works for small binaries today. We could implement chunked
  #     upload later; for now, fail loudly with a clear message.
  defp push_binary(sprite, {:release_url, signed_url}) do
    info("downloading binary on the sprite from a signed release URL...")

    {output, code} =
      Sprites.cmd(
        sprite,
        "curl",
        ["-fsSL", signed_url, "-o", @remote_binary, "--create-dirs"],
        stderr_to_stdout: true,
        timeout: 300_000
      )

    if code != 0, do: raise("sprite-side curl failed (code #{code}):\n#{output}")

    {_, 0} = Sprites.cmd(sprite, "chmod", ["+x", @remote_binary])
    info("binary downloaded.")
  end

  defp push_binary(sprite, {:local, path}) do
    size = File.stat!(path).size
    info("pushing local build (#{human_size(size)}) to sprite via fs/write...")

    if size > 18_000_000 do
      FountainCli.die(
        "local binary is #{human_size(size)} — sprites.dev's /fs/write endpoint " <>
          "rejects bodies above ~20 MB. Use a tagged release instead (`mix aod.up " <>
          "--release vX.Y.Z`), which downloads on the sprite via curl and avoids " <>
          "the limit."
      )
    end

    fs = Sprites.filesystem(sprite, "/")
    binary = File.read!(path)
    :ok = Sprites.Filesystem.write(fs, @remote_binary, binary, mode: 0o755)
    info("binary pushed.")
  end

  # ── upgrade ──────────────────────────────────────────────────────

  defp upgrade(client, name, binary_source, sprites_token) do
    info("upgrading sprite '#{name}' in place...")
    sprite = Sprites.sprite(client, name)

    info("recovering env from #{@remote_start_sh}...")
    env = read_existing_env(sprite)

    public_url =
      env_get(env, "AOD_PUBLIC_URL") ||
        FountainCli.die("could not recover AOD_PUBLIC_URL from existing #{@remote_start_sh}")

    admin_token = env_get(env, "ADMIN_TOKEN") || "<unchanged>"

    # Refresh SPRITES_TOKEN + AI provider tokens from the operator's
    # current shell. Older deploys didn't set these at all; the
    # upgrade is the recovery path.
    env = put_env(env, "SPRITES_TOKEN", sprites_token)
    env = refresh_passthrough(env)

    push_binary(sprite, binary_source)

    info("rewriting #{@remote_start_sh} (env shape may have changed)...")
    fs = Sprites.filesystem(sprite, "/")
    :ok = Sprites.Filesystem.write(fs, @remote_start_sh, start_script(env), mode: 0o755)

    info("recreating sprite-env service so it picks up the new binary...")
    {_, _} = Sprites.cmd(sprite, "/.sprite/bin/sprite-env", ["services", "delete", "aod"])

    {out, code} =
      Sprites.cmd(
        sprite,
        "/.sprite/bin/sprite-env",
        [
          "services",
          "create",
          "aod",
          "--cmd",
          @remote_start_sh,
          "--http-port",
          Integer.to_string(@port),
          "--no-stream"
        ],
        timeout: 30_000,
        stderr_to_stdout: true
      )

    if code != 0, do: raise("sprite-env services create failed (code #{code}):\n#{out}")
    info("service registered: #{String.trim(out)}")

    info("polling /health...")
    wait_for_health(public_url)

    IO.puts("""

    ============================================================
    AoD upgraded!

      URL:           #{public_url}
      ADMIN_TOKEN:   #{admin_token}
      Sprite name:   #{name}

    ============================================================
    """)
  end

  defp read_existing_env(sprite) do
    {output, code} =
      Sprites.cmd(sprite, "cat", [@remote_start_sh], stderr_to_stdout: true)

    if code != 0 do
      FountainCli.die("could not read #{@remote_start_sh} (exit #{code}):\n#{output}")
    end

    parse_start_sh(output)
  end

  # ── start.sh writer/parser ───────────────────────────────────────
  # We wrote start.sh ourselves with `export KEY='value'` lines, where
  # any embedded `'` was encoded as `'"'"'`. So the parser is the
  # inverse — pull out KEY/value pairs and unwrap.

  @doc false
  def parse_start_sh(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^export ([A-Z_][A-Z0-9_]*)=(.*)$/, String.trim(line)) do
        [_, key, value] -> [{key, unquote_shell(value)}]
        _ -> []
      end
    end)
  end

  @doc false
  def shell_quote(value) do
    "'" <> String.replace(value, "'", ~S('"'"')) <> "'"
  end

  defp unquote_shell("'" <> rest) do
    rest
    |> String.replace_suffix("'", "")
    |> String.replace(~S('"'"'), "'")
  end

  defp unquote_shell(s), do: s

  defp env_get(env, key) do
    case List.keyfind(env, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp start_script(env) do
    exports =
      env
      |> Enum.map(fn {k, v} -> "export #{k}=#{shell_quote(v)}" end)
      |> Enum.join("\n")

    """
    #!/bin/sh
    set -eu
    #{exports}
    exec #{@remote_binary} start
    """
  end

  # Env vars that flow through from the operator's shell to the
  # deployed sprite. Anything claude / codex / gemini / opencode might
  # want for auth, plus tracing config if the operator has it set.
  # If a var isn't set on the operator's side it's just omitted (the
  # AoD server tolerates missing values for optional providers).
  @passthrough_env_vars [
    "CLAUDE_CODE_OAUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_HEADERS"
  ]

  defp build_env(secrets, public_url, sprites_token) do
    %URI{host: host} = URI.parse(public_url)

    base = [
      {"PHX_SERVER", "1"},
      {"PHX_HOST", host},
      {"PORT", Integer.to_string(@port)},
      {"RELEASE_NAME", "aod_server"},
      {"SECRET_KEY_BASE", secrets.secret_key_base},
      {"ADMIN_TOKEN", secrets.admin_token},
      {"SECRETS_KEY", secrets.secrets_key},
      {"SPRITES_TOKEN", sprites_token},
      {"DATABASE_PATH", @remote_db},
      {"AOD_PUBLIC_URL", public_url}
    ]

    base ++ passthrough_env()
  end

  defp passthrough_env do
    for key <- @passthrough_env_vars,
        value = System.get_env(key) || load_dot_env(key),
        is_binary(value) and value != "",
        do: {key, value}
  end

  # Set or replace a single env var in the keyword-list-shaped env.
  defp put_env(env, key, value) do
    [{key, value} | List.keydelete(env, key, 0)]
  end

  # Refresh all passthrough env vars from the operator's current
  # shell. Any keys the operator doesn't have set are removed from
  # the existing env (operators dropping a provider should clear it
  # cleanly; otherwise an old token lingers indefinitely).
  defp refresh_passthrough(env) do
    operator_set =
      for key <- @passthrough_env_vars,
          value = System.get_env(key) || load_dot_env(key),
          is_binary(value) and value != "",
          into: %{},
          do: {key, value}

    env =
      Enum.reduce(@passthrough_env_vars, env, fn key, acc ->
        case Map.fetch(operator_set, key) do
          {:ok, v} -> put_env(acc, key, v)
          :error -> List.keydelete(acc, key, 0)
        end
      end)

    env
  end

  defp extract_public_url(info, port) do
    candidates =
      for k <- ~w(public_url url hostname public_hostname),
          v = Map.get(info, k) || get_in(info, [k]),
          is_binary(v),
          do: v

    case candidates do
      [host_or_url | _] ->
        cond do
          String.starts_with?(host_or_url, "http") ->
            host_or_url

          true ->
            "https://#{host_or_url}:#{port}"
        end

      [] ->
        for {_k, v} <- info, is_map(v), reduce: nil do
          acc -> acc || extract_public_url(v, port)
        end
    end
  end

  defp wait_for_health(url, attempts \\ 60) do
    Enum.reduce_while(1..attempts, nil, fn n, _ ->
      case Req.get(url <> "/health", retry: false, receive_timeout: 5_000) do
        {:ok, %{status: 200, body: %{"status" => "ok"}}} ->
          info("/health 200 OK after #{n} tries.")
          {:halt, :ok}

        {:ok, %{status: code}} ->
          info("attempt #{n}: /health -> #{code}")
          Process.sleep(2_000)
          {:cont, nil}

        {:error, reason} ->
          info("attempt #{n}: #{inspect(reason)}")
          Process.sleep(2_000)
          {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      _ -> raise "/health never responded 200 OK"
    end
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp random_url64(bytes),
    do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)

  defp human_size(bytes) when bytes > 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp human_size(bytes), do: "#{bytes} B"

  defp info(msg), do: IO.puts("→ #{msg}")

  defp load_dot_env(key) do
    path = Path.expand(".env")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(String.trim(line), "=", parts: 2) do
          [^key, value] -> value |> String.trim() |> String.trim("\"")
          _ -> nil
        end
      end)
    end
  end
end
