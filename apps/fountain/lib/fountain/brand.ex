defmodule Fountain.Brand do
  @moduledoc """
  The name this deployment goes by.

  Fountain is the engine: the CLI, the API, the SDK, the env vars and the
  manual all carry its name, and none of that changes per deployment. What
  does change is what the *chrome* says: the sidebar header, the `<title>`,
  the sign-in page, the OAuth consent screen and the subject line of every
  email. A hosted deployment sold under another brand (`PRODUCT_NAME`) puts
  that brand there and nowhere else, the way GitLab.com is GitLab and Grafana
  Cloud is Grafana.

  The manual is the one place both names show up, on purpose: a reader of the
  hosted docs types `fountain auth login`, so the word Fountain has to be on
  the page. `hosted?/0` is what lets the docs layout explain that once, at the
  top, rather than the reader working it out.
  """

  @engine "Fountain"

  @doc "The engine's name. Never configurable; it is what the code is called."
  @spec engine() :: String.t()
  def engine, do: @engine

  @doc """
  The deployment's brand: `PRODUCT_NAME`, or `"Fountain"` when unset or blank.
  """
  @spec name() :: String.t()
  def name do
    case Application.get_env(:fountain, :product_name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @engine
          trimmed -> trimmed
        end

      _ ->
        @engine
    end
  end

  @doc "True when the deployment is branded as something other than the engine."
  @spec hosted?() :: boolean()
  def hosted?, do: name() != @engine
end
