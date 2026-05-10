defmodule FountainCli do
  @moduledoc """
  Fountain CLI entry point. Dispatches top-level subcommands.
  """

  def main(args) do
    case args do
      ["auth" | rest] -> FountainCli.Auth.dispatch(rest)
      ["keys" | rest] -> FountainCli.Keys.dispatch(rest)
      ["env" | rest] -> FountainCli.Env.dispatch(rest)
      ["agent" | rest] -> FountainCli.Agent.dispatch(rest)
      ["vault" | rest] -> FountainCli.Vault.dispatch(rest)
      ["conv" | rest] -> FountainCli.Conv.dispatch(rest)
      ["run" | rest] -> FountainCli.Conv.run(rest)
      ["apply" | rest] -> FountainCli.Apply.dispatch(rest)
      ["--help"] -> print_help()
      ["help"] -> print_help()
      [] -> print_help()
      [cmd | _] -> die("unknown command: #{cmd}\nRun `fountain help` for usage.")
    end
  end

  @doc "Print an error message to stderr and exit 1."
  def die(msg) do
    IO.puts(:stderr, "fountain: " <> msg)
    System.halt(1)
  end

  defp print_help do
    IO.puts("""
    Usage: fountain <command> [args]

    Auth:
      auth login [--profile <name>]    Authenticate and save credentials
      auth logout [--profile <name>]   Remove saved credentials
      auth whoami [--profile <name>]   Print current user info

    API Keys:
      keys list                        List API keys
      keys create <name>               Create a new API key
      keys revoke <id>                 Revoke an API key

    Resources:
      env <list|show>                  Manage environments
      agent <list|show>                Manage agents
      vault <list|show|create|...>     Manage vaults
      conv <list|show|stream|...>      Manage conversations
      run <agent> -p <prompt>          Run an agent (shorthand)
      apply -f <path>                  Apply resource definitions

    Credentials are read from FOUNTAIN_API_KEY env var or ~/.fountain/credentials.
    Use FOUNTAIN_PROFILE or --profile to select a non-default profile.
    """)
  end
end
