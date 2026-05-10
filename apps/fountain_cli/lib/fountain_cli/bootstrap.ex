defmodule FountainCli.Bootstrap do
  @moduledoc """
  OTP Application module that runs the CLI when started.

  In a Burrito-wrapped release, the bin script invokes the OTP app
  via `bin/aod start` (or `daemon`). For the CLI use case we don't
  want a long-running server; we want to run `FountainCli.main/1` with
  the args the user passed and exit.

  Burrito captures argv via `Burrito.Util.Args.argv/0`. When running
  the binary outside Burrito (e.g. inside a vanilla `mix release`
  invocation), `System.argv/0` is the fallback.

  We detach the actual work into a Task so the Application start
  callback can return `{:ok, pid}` cleanly. The Task halts the VM
  on completion.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    if cli_release?() do
      # Burrito's documented pattern: do the work in start/2 directly
      # and System.halt at the end. The earlier Task-supervisor approach
      # could deadlock because Application.start was returning before
      # the Task got scheduled cleanly.
      args = read_argv()

      try do
        FountainCli.main(args)
        System.halt(0)
      rescue
        e ->
          IO.puts(:stderr, "aod: " <> Exception.message(e))
          System.halt(1)
      end
    else
      # `mix test`, `iex -S mix`, the server release (which depends on
      # fountain_cli for FountainCli.Substitution but isn't running the CLI), etc.
      Supervisor.start_link([], strategy: :one_for_one, name: FountainCli.Bootstrap.Sup)
    end
  end

  # Three contexts to distinguish:
  #   * dev/test/iex      — Mix is loaded as an OTP app
  #   * CLI release       — Mix not loaded; fountain not loaded
  #   * server release    — Mix not loaded; fountain IS loaded
  #     (the server release bundles fountain_cli for FountainCli.Substitution)
  # We only run main in the CLI release.
  #
  # Burrito doesn't propagate `RELEASE_NAME` to the runtime env, so an
  # env-var or config-flag gate (set in runtime.exs) ends up dormant.
  # Inspecting loaded applications works regardless.
  defp cli_release? do
    Application.spec(:mix) == nil and Application.spec(:fountain) == nil
  end

  # In a Burrito-wrapped binary, the Zig wrapper passes the user's
  # argv as plain arguments to the Erlang VM (i.e. anything after a
  # `-extra` switch). `:init.get_plain_arguments/0` is what reads
  # them; that's also exactly what `Burrito.Util.Args.argv/0` does
  # internally. We can't call the Burrito helper directly because the
  # dep is `runtime: false` and its modules aren't loaded in the
  # release. Inlining sidesteps the issue without bloating the binary
  # with Burrito's own runtime code.
  defp read_argv do
    :init.get_plain_arguments() |> Enum.map(&to_string/1)
  end
end
