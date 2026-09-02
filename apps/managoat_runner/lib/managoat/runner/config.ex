defmodule Managoat.Runner.Config do
  @moduledoc """
  The library's one setting, read from its own otp_app:

      config :managoat_runner, host: MyApp.RunnerHost

  `host` is the module implementing `Managoat.Runner.Host`. There is no
  default: a consumer that forgets it gets an error naming the key, not a
  connection that registers nowhere and a `call/3` that finds no runner
  online. The `WebSock` init map may carry `host:` too, and that overrides
  the configured one for that connection (it is what lets a test run two
  hosts side by side); `nil` counts as unset either way.
  """

  @doc """
  The host module: `overrides[:host]` when present, else the configured one.
  Raises when neither names a module.
  """
  @spec host!(map()) :: module()
  def host!(overrides \\ %{}) when is_map(overrides) do
    case Map.get(overrides, :host) || Application.get_env(:managoat_runner, :host) do
      module when is_atom(module) and not is_nil(module) ->
        module

      other ->
        raise ArgumentError,
              "no runner host configured: set `config :managoat_runner, host: Module` " <>
                "(a module implementing Managoat.Runner.Host; " <>
                "Managoat.Runner.Host.Local is the reference), got #{inspect(other)}"
    end
  end
end
