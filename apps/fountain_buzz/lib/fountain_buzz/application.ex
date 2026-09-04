defmodule FountainBuzz.Application do
  @moduledoc """
  The extension's own supervision tree (ADR 0043, #1507).

  This is an OTP application that depends on `:fountain`, so OTP starts the host
  first and stops it last: the Repo and the Endpoint are up before anything here
  starts, and this tree is down before the Repo goes away. The host aggregates
  none of these children, and a crash in this supervisor cannot reach
  `Fountain.Supervisor`.

  Starting *after* the Endpoint is not incidental. A harness runs `fountain acp`
  as its ACP child, and that child talks HTTP back to this same server — under
  the old arrangement, where `Fountain.Application` listed these children before
  `FountainWeb.Endpoint`, the boot sweep raced the listener it depends on.

  ## Compiled in is not the same as switched on

  Nothing starts unless `FountainBuzz.Extension` is named in
  `config :fountain, :extensions` and answers `enabled?/0`. An image that
  carries this app but does not configure it runs no registry, no supervisor and
  no sweep — which is what "build-time install, runtime enable" has to mean if
  it means anything.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: FountainBuzz.Supervisor.Root)
  end

  defp children do
    if installed?() do
      [
        # The same Horde shape the conversation tree uses: one harness per Buzz
        # identity, addressable cluster-wide, surviving node loss.
        {Horde.Registry, [name: FountainBuzz.Registry, keys: :unique, members: :auto]},
        {Horde.DynamicSupervisor,
         [
           name: FountainBuzz.Supervisor,
           strategy: :one_for_one,
           distribution_strategy: Horde.UniformDistribution,
           members: :auto,
           max_restarts: 100,
           max_seconds: 10
         ]},
        # Stands the enabled identities up once both are ready. Inert until a
        # `buzz-acp` binary path is configured, so this costs nothing on an
        # instance that installed the extension without the binary.
        FountainBuzz.BootSweep
      ]
    else
      Logger.info("fountain_buzz is compiled in but not configured; starting nothing")
      []
    end
  end

  defp installed? do
    FountainBuzz.Extension in Fountain.Extensions.installed()
  end
end
