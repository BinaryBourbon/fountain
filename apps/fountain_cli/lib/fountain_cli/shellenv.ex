defmodule FountainCli.Shellenv do
  @moduledoc """
  `aod shellenv --name <sprite-name>` — recover an instance's
  `AOD_BASE_URL` + `AOD_TOKEN` from its deployed start.sh and print
  shell `export` lines on stdout.

  Designed for `eval`:

      eval "$(aod shellenv --name aod-host-1730758800)"

  Stdout is exports only (so the `eval` is safe). All informational
  output goes to stderr.
  """

  alias FountainCli.Up

  @remote_start_sh "/opt/aod/start.sh"

  def dispatch(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [name: :string])

    name =
      opts[:name] ||
        FountainCli.die("usage: aod shellenv --name <sprite-name>")

    Application.ensure_all_started(:req)
    Application.ensure_all_started(:gun)
    Application.ensure_all_started(:sprites)

    sprites_token =
      System.get_env("SPRITES_TOKEN") ||
        FountainCli.die("SPRITES_TOKEN not set")

    client = Sprites.new(sprites_token)

    case Sprites.get_sprite(client, name) do
      {:ok, _info} -> :ok
      {:error, {:not_found, _}} -> FountainCli.die("no sprite named '#{name}'")
      {:error, reason} -> FountainCli.die("could not check sprite '#{name}': #{inspect(reason)}")
    end

    sprite = Sprites.sprite(client, name)

    {output, code} = Sprites.cmd(sprite, "cat", [@remote_start_sh], stderr_to_stdout: true)

    if code != 0 do
      FountainCli.die("could not read #{@remote_start_sh} on '#{name}' (exit #{code}):\n#{output}")
    end

    env = Up.parse_start_sh(output)

    base_url =
      lookup(env, "AOD_PUBLIC_URL") ||
        FountainCli.die("AOD_PUBLIC_URL missing from #{@remote_start_sh} on '#{name}'")

    token =
      lookup(env, "ADMIN_TOKEN") ||
        FountainCli.die("ADMIN_TOKEN missing from #{@remote_start_sh} on '#{name}'")

    IO.puts(:stderr, "# aod shellenv: recovered from sprite '#{name}'")
    IO.puts("export AOD_BASE_URL=#{Up.shell_quote(base_url)}")
    IO.puts("export AOD_TOKEN=#{Up.shell_quote(token)}")
  end

  defp lookup(env, key) do
    case List.keyfind(env, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
