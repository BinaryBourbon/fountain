defmodule Managoat.Sandbox.Config do
  @moduledoc """
  Per-adapter settings, read from this library's own otp_app.

  Each adapter keeps its settings under its module name:

      config :managoat_sandbox, Managoat.Sandbox.Sprites,
        token: System.get_env("SPRITES_TOKEN"),
        base_url: "https://api.sprites.dev",
        timeout_ms: 30_000

      config :managoat_sandbox, Managoat.Sandbox.E2B, api_key: ..., template: "base"
      config :managoat_sandbox, Managoat.Sandbox.Daytona, api_key: ..., snapshot: nil
      config :managoat_sandbox, Managoat.Sandbox.Retry, base_ms: 250

  The host application decides where a value comes from (an environment
  variable, a secrets store); the library reads nothing but `:managoat_sandbox`.
  A key set to `nil` counts as unset and yields the default, so a host may
  write every key unconditionally from its environment.
  """

  @doc "The value of `key` in `scope`'s settings, or `default` when unset or nil."
  @spec get(module(), atom(), term()) :: term()
  def get(scope, key, default \\ nil) when is_atom(scope) and is_atom(key) do
    case :managoat_sandbox |> Application.get_env(scope, []) |> Keyword.get(key) do
      nil -> default
      value -> value
    end
  end
end
