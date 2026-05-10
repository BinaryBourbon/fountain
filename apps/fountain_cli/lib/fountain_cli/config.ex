defmodule FountainCli.Config do
  @moduledoc """
  Resolves the API key and base URL for the active profile.

  API key precedence:
    1. `FOUNTAIN_API_KEY` env var
    2. `api_key` from `~/.fountain/credentials` (active profile)

  Base URL precedence:
    1. `FOUNTAIN_BASE_URL` env var
    2. `base_url` from `~/.fountain/credentials` (active profile)
    3. Compile-time default (`https://fountain.dev`)
  """

  @compile_default Application.compile_env(:fountain_cli, :base_url, "https://fountain.dev")

  @doc """
  Return the API key for `opts`.
  `FOUNTAIN_API_KEY` env var takes precedence over the credentials file.
  """
  @spec api_key(keyword()) :: String.t()
  def api_key(opts \\ []) do
    case System.get_env("FOUNTAIN_API_KEY") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        profile = FountainCli.Credentials.profile_name(opts)

        case FountainCli.Credentials.read_profile(profile) do
          %{"api_key" => key} when is_binary(key) and key != "" ->
            key

          _ ->
            FountainCli.die(
              "FOUNTAIN_API_KEY is not set. " <>
                "Run `fountain auth login` or export the FOUNTAIN_API_KEY environment variable."
            )
        end
    end
  end

  @doc "Return the base URL for `opts`, with any trailing slash removed."
  @spec base_url(keyword()) :: String.t()
  def base_url(opts \\ []) do
    url =
      case System.get_env("FOUNTAIN_BASE_URL") do
        url when is_binary(url) and url != "" ->
          url

        _ ->
          profile = FountainCli.Credentials.profile_name(opts)

          case FountainCli.Credentials.read_profile(profile) do
            %{"base_url" => url} when is_binary(url) and url != "" -> url
            _ -> @compile_default
          end
      end

    String.trim_trailing(url, "/")
  end
end
