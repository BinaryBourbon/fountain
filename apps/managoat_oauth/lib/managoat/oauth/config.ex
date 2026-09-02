defmodule Managoat.OAuth.Config do
  @moduledoc """
  What one instance of `Managoat.OAuth` runs with, read from the host's own
  otp_app under the instance module's key:

      config :my_app, MyApp.OAuth,
        repo: MyApp.Repo,
        clients: [%{id: "spa", name: "SPA", redirect_uris: ["https://spa.example/"]}],
        prefix: nil

  `repo` has no default: a consumer that forgets it gets an error naming
  the key, not a query against nothing. `host` comes from the `use` line and
  is checked here too, so a nil in either place is the same error. `clients`
  defaults to none and is normalised on every read (atom or string keys,
  `name` falling back to `id`), so a JSON registry decodes straight into it.
  `prefix` is the Postgres schema the two tables live in, `nil` for the
  default; it is passed to every repo call and matches the `prefix:` given
  to `Managoat.OAuth.Migration.up/1`. `nil` counts as unset for all three.
  """

  alias Managoat.OAuth.Clients

  @type t :: %__MODULE__{
          repo: module(),
          host: module(),
          clients: [Clients.client()],
          prefix: String.t() | nil
        }

  defstruct [:repo, :host, :prefix, clients: []]

  @doc """
  The instance's config, or a raise naming what is missing. Read on every
  call rather than cached: the client list is runtime configuration that a
  host may set from its environment after compile.
  """
  @spec load!(atom(), module(), module() | nil) :: t()
  def load!(otp_app, instance, host) when is_atom(otp_app) and is_atom(instance) do
    env = Application.get_env(otp_app, instance) || []

    unless Keyword.keyword?(env) do
      raise ArgumentError,
            "config #{inspect(otp_app)}, #{inspect(instance)} must be a keyword list " <>
              "(repo:, clients:, prefix:), got #{inspect(env)}"
    end

    %__MODULE__{
      repo: repo!(otp_app, instance, Keyword.get(env, :repo)),
      host: host!(instance, host),
      clients: Clients.normalize(Keyword.get(env, :clients) || []),
      prefix: Keyword.get(env, :prefix)
    }
  end

  @doc "The options every repo call takes: the prefix when there is one."
  @spec repo_opts(t()) :: keyword()
  def repo_opts(%__MODULE__{prefix: nil}), do: []
  def repo_opts(%__MODULE__{prefix: prefix}), do: [prefix: prefix]

  defp repo!(_otp_app, _instance, repo) when is_atom(repo) and not is_nil(repo), do: repo

  defp repo!(otp_app, instance, other) do
    raise ArgumentError,
          "no repo configured for #{inspect(instance)}: set " <>
            "`config #{inspect(otp_app)}, #{inspect(instance)}, repo: MyApp.Repo`, " <>
            "got #{inspect(other)}"
  end

  defp host!(_instance, host) when is_atom(host) and not is_nil(host), do: host

  defp host!(instance, other) do
    raise ArgumentError,
          "no host for #{inspect(instance)}: write " <>
            "`use Managoat.OAuth, otp_app: :my_app, host: Module` with a module " <>
            "implementing Managoat.OAuth.Host, got #{inspect(other)}"
  end
end
