defmodule FountainCli.Down do
  @moduledoc """
  Tear down an AoD sprite previously deployed with `aod up`.

  Reads `SPRITES_TOKEN` from env (or a `.env` in the current dir).
  Looks up the named sprite and destroys it.

  Usage:
      aod down <sprite-name>

  The sprite name was printed when you ran `aod up`. If you've lost
  track, list everything in your sprites.dev account in the dashboard.
  """

  @doc """
  Entry point. Parses args (passed through from either the Mix task
  wrapper or FountainCli.main) and runs the destroy.
  """
  def dispatch(args) do
    {_opts, positional, _} = OptionParser.parse(args, strict: [])

    name =
      case positional do
        [n | _] -> n
        _ -> FountainCli.die("usage: aod down <sprite-name>")
      end

    Application.ensure_all_started(:req)
    Application.ensure_all_started(:gun)
    Application.ensure_all_started(:sprites)

    token =
      System.get_env("SPRITES_TOKEN") || load_dot_env("SPRITES_TOKEN") ||
        FountainCli.die("SPRITES_TOKEN not set")

    client = Sprites.new(token)
    destroy(client, name)
  end

  @doc false
  def destroy(client, name) do
    info("destroying sprite '#{name}'...")
    sprite = Sprites.sprite(client, name)
    :ok = Sprites.destroy(sprite)
    info("destroyed.")
  end

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
