defmodule Fountain.Extensions do
  @moduledoc """
  The registry of configured `Fountain.Extension`s (ADR 0043, #1505).

  There is no runtime registration. `config :fountain, :extensions, [Mod, ...]`
  is the whole truth: this module reads it, validates it once at boot, and
  answers the two questions the host asks per request.

      configured()  # every module named in config, enabled or not
      installed()   # the configured ones whose `enabled?/0` says yes

  `installed/0` is what every dispatch point uses, so a configured extension
  that cannot run on this deployment is indistinguishable from one that was
  never configured — no routes, no MCP servers, no calls.

  ## Failing closed

  `validate!/0` runs from `Fountain.Application.start/2` and **raises**, so a
  deployment whose extension configuration is wrong refuses to boot rather than
  serving a surface nobody checked. It refuses a module that is not an
  extension, a duplicate id, a duplicate or malformed API prefix, a prefix a
  core route already claims, and a half-declared HTTP surface (a prefix with no
  plug, or a plug with no prefix).

  The core-route check reads `FountainWeb.Router.__routes__/0` rather than a
  hand-kept list, so a route added to the router next month automatically
  reserves its prefix. A core route always wins: dispatch only ever sees a
  request Phoenix matched to no core route at all.
  """

  require Logger

  @type t :: module()

  @doc "Every extension module named in configuration, in configured order."
  @spec configured() :: [t()]
  def configured, do: Application.get_env(:fountain, :extensions, [])

  @doc """
  The configured extensions this deployment can actually run, in configured
  order. Everything that dispatches uses this, never `configured/0`.

  Takes the list for the same reason `validate/2` does: a test can hand it an
  extension whose `enabled?/0` misbehaves without installing that extension in
  the VM for every other test to trip over.
  """
  @spec installed() :: [t()]
  def installed, do: installed(configured())

  @doc "See `installed/0`. Takes the list, so a test can supply one."
  @spec installed([t()]) :: [t()]
  def installed(modules) when is_list(modules), do: Enum.filter(modules, &enabled?/1)

  @doc """
  The installed extension that serves `/api/<prefix>`, or `nil`.

  `nil` covers all three of "no extension declares it", "the one that does is
  disabled here" and "nothing is configured" — the caller answers 404 to each,
  because they are the same answer to a client.
  """
  @spec find_by_prefix(String.t()) :: t() | nil
  def find_by_prefix(prefix) when is_binary(prefix) do
    Enum.find(installed(), fn ext -> ext.api_prefix() == prefix end)
  end

  def find_by_prefix(_prefix), do: nil

  @doc """
  Every installed extension's MCP servers for this conversation, concatenated
  in configured order.

  **A failing extension costs only its own servers.** A raise, throw or exit in
  one `conversation_mcp_servers/2` is caught here, logged, and contributes `[]`;
  the other extensions and the host's own team, comms and caller servers are
  untouched and the turn goes on. The alternative — letting it propagate — kills
  the turn kick, which means a broken optional integration takes the
  conversation with it.
  """
  @spec conversation_mcp_servers(String.t() | nil, String.t() | nil) :: [map()]
  def conversation_mcp_servers(conversation_id, callback_token)
      when is_binary(conversation_id) and is_binary(callback_token) do
    Enum.flat_map(installed(), &safe_mcp_servers(&1, conversation_id, callback_token))
  end

  def conversation_mcp_servers(_conversation_id, _callback_token), do: []

  defp safe_mcp_servers(ext, conversation_id, callback_token) do
    case ext.conversation_mcp_servers(conversation_id, callback_token) do
      servers when is_list(servers) ->
        servers

      other ->
        Logger.error(
          "extension #{inspect(ext)} conversation_mcp_servers/2 returned #{inspect(other)}, " <>
            "expected a list; contributing none"
        )

        []
    end
  rescue
    error ->
      log_contribution_failure(ext, conversation_id, :error, error, __STACKTRACE__)
      []
  catch
    kind, reason ->
      log_contribution_failure(ext, conversation_id, kind, reason, __STACKTRACE__)
      []
  end

  defp log_contribution_failure(ext, conversation_id, kind, reason, stacktrace) do
    Logger.error(
      "extension #{inspect(ext)} conversation_mcp_servers/2 failed for conversation " <>
        "#{conversation_id}; contributing none\n" <>
        Exception.format(kind, reason, stacktrace)
    )
  end

  # `enabled?/0` is asked per dispatch, so a raising one must not take the
  # request with it. A extension that cannot answer is not installed.
  defp enabled?(ext) do
    ext.enabled?() == true
  rescue
    error ->
      Logger.error(
        "extension #{inspect(ext)} enabled?/0 raised; treating as not installed\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      false
  end

  ## ─── Validation ──────────────────────────────────────────────────────────

  @doc """
  Validate the configured extensions, raising on anything wrong.

  Called from `Fountain.Application.start/2`, before any child starts: a
  deployment with a bad extension list fails to boot, loudly, instead of
  serving a surface whose shape nobody checked.
  """
  @spec validate!() :: :ok
  def validate!, do: validate!(configured())

  @doc "See `validate!/0`. Takes the list, for tests and for a dry run."
  @spec validate!([t()]) :: :ok
  def validate!(modules) do
    case validate(modules) do
      :ok ->
        :ok

      {:error, message} ->
        raise ArgumentError,
              "invalid :extensions configuration for :fountain — #{message}\n\n" <>
                "Fix config :fountain, :extensions. See decisions/0043-first-party-extensions.md."
    end
  end

  @doc """
  Validate a list of extension modules against the core routes.

  Returns `:ok` or `{:error, message}` where the message names the offending
  module. Pure: it reads the router's compiled route table and nothing else, so
  a test can call it on any list without touching configuration.
  """
  @spec validate([t()], MapSet.t(String.t()) | nil) :: :ok | {:error, String.t()}
  def validate(modules, reserved \\ nil) do
    reserved = reserved || reserved_prefixes()

    with :ok <- check_all(modules, &check_module/1),
         :ok <- check_unique(modules, & &1.id(), "id"),
         :ok <- check_all(modules, &check_http_surface/1),
         :ok <- check_all(modules, &check_prefix_shape/1),
         :ok <- check_unique(modules, & &1.api_prefix(), "API prefix") do
      check_all(modules, &check_prefix_free(&1, reserved))
    end
  end

  @doc """
  The `/api/<segment>` prefixes the core router already claims.

  Read from the compiled route table, so it needs no maintenance: a route added
  to `FountainWeb.Router` reserves its prefix from the same commit. Dynamic
  segments (`/api/:thing`) are skipped — nothing static can collide with them,
  and an extension prefix is always static.
  """
  @spec reserved_prefixes() :: MapSet.t(String.t())
  def reserved_prefixes do
    FountainWeb.Router.__routes__()
    |> Enum.flat_map(fn route ->
      case String.split(route.path, "/", trim: true) do
        ["api", ":" <> _dynamic | _rest] -> []
        ["api", "*" <> _glob | _rest] -> []
        ["api", segment | _rest] -> [segment]
        _other -> []
      end
    end)
    |> MapSet.new()
  end

  defp check_all(modules, fun) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case fun.(module) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  @required_callbacks [
    id: 0,
    enabled?: 0,
    api_prefix: 0,
    api_plug: 0,
    conversation_mcp_servers: 2
  ]

  defp check_module(module) when is_atom(module) do
    loaded? = Code.ensure_loaded?(module)

    implements? =
      loaded? and
        Enum.all?(@required_callbacks, fn {fun, arity} ->
          function_exported?(module, fun, arity)
        end)

    cond do
      not loaded? ->
        {:error, "#{inspect(module)} is not a loadable module"}

      implements? ->
        :ok

      true ->
        {:error,
         "#{inspect(module)} does not implement Fountain.Extension " <>
           "(add `use Fountain.Extension, id: :...`)"}
    end
  end

  defp check_module(other) do
    {:error, "#{inspect(other)} is not a module"}
  end

  defp check_http_surface(module) do
    case {module.api_prefix(), module.api_plug()} do
      {nil, nil} ->
        :ok

      {prefix, nil} when is_binary(prefix) ->
        {:error, "#{inspect(module)} declares api_prefix #{inspect(prefix)} but no api_plug"}

      {nil, plug} ->
        {:error, "#{inspect(module)} declares api_plug #{inspect(plug)} but no api_prefix"}

      {prefix, _plug} when is_binary(prefix) ->
        :ok

      {prefix, _plug} ->
        {:error, "#{inspect(module)} api_prefix must be a string, got #{inspect(prefix)}"}
    end
  end

  # One lowercase path segment. Deliberately narrow: a prefix carrying a slash,
  # a dot or an uppercase letter is a prefix that reads differently in a route,
  # in an OpenAPI path and in a URL a person types.
  @prefix_shape ~r/^[a-z][a-z0-9-]*$/

  defp check_prefix_shape(module) do
    case module.api_prefix() do
      nil ->
        :ok

      prefix when is_binary(prefix) ->
        if Regex.match?(@prefix_shape, prefix) do
          :ok
        else
          {:error,
           "#{inspect(module)} api_prefix #{inspect(prefix)} is not one lowercase path " <>
             "segment matching #{inspect(Regex.source(@prefix_shape))}"}
        end

      _other ->
        :ok
    end
  end

  defp check_prefix_free(module, reserved) do
    prefix = module.api_prefix()

    if is_binary(prefix) and MapSet.member?(reserved, prefix) do
      {:error,
       "#{inspect(module)} api_prefix #{inspect(prefix)} is already served by a core route " <>
         "at /api/#{prefix}"}
    else
      :ok
    end
  end

  defp check_unique(modules, fun, label) do
    modules
    |> Enum.map(fn module -> {module, fun.(module)} end)
    |> Enum.reject(fn {_module, value} -> is_nil(value) end)
    |> Enum.group_by(fn {_module, value} -> value end, fn {module, _value} -> module end)
    |> Enum.find(fn {_value, mods} -> length(mods) > 1 end)
    |> case do
      nil ->
        :ok

      {value, mods} ->
        {:error,
         "#{label} #{inspect(value)} is declared by more than one extension: " <>
           Enum.map_join(mods, ", ", &inspect/1)}
    end
  end
end
