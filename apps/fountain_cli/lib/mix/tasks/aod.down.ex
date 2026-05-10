defmodule Mix.Tasks.Aod.Down do
  @moduledoc """
  Thin wrapper around `FountainCli.Down.dispatch/1`. Both `mix aod.down`
  and `./aod down` (from the released binary) hit the same code
  path. See `FountainCli.Down` for the full docs.

  Usage:
      SPRITES_TOKEN=... mix aod.down <sprite-name>
  """
  use Mix.Task

  @shortdoc "Destroy a Sprite previously deployed with mix aod.up"

  @impl Mix.Task
  def run(args), do: FountainCli.Down.dispatch(args)
end
