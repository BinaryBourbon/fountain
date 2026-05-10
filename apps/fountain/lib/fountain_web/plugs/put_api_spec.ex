defmodule FountainWeb.Plugs.PutApiSpec do
  @moduledoc """
  Drop-in replacement for `OpenApiSpex.Plug.PutApiSpec`.

  The upstream plug builds the spec on the first request and caches it
  via `OpenApiSpex.Plug.Cache.adapter()` (`:persistent_term` by default).
  That's correct in prod, but in dev it means a newly-added controller
  (e.g. just-introduced `VaultController`) makes its routes return 500
  with `operationId was not found in action API spec` until the server
  restarts — Phoenix code-reloads the route table, but the cache is
  still pointing at a spec built before the new module existed.

  When `:cache_api_spec` is `false` (set in `config/dev.exs`) we erase
  the cache on every request before delegating, forcing
  `get_spec_and_operation_lookup/1` to rebuild from scratch. Per-request
  rebuild costs single-digit ms and only runs in dev. Otherwise we
  delegate straight through.
  """

  @behaviour Plug

  @cache? Application.compile_env(:fountain, :cache_api_spec, true)

  @impl true
  def init(opts) do
    %{
      module:
        opts[:module] ||
          raise("A :module option is required, but none was given to #{__MODULE__}.init/1"),
      cache?: @cache?
    }
  end

  @impl true
  def call(conn, %{module: module, cache?: false}) do
    OpenApiSpex.Plug.Cache.adapter().erase(module)
    OpenApiSpex.Plug.PutApiSpec.call(conn, module)
  end

  def call(conn, %{module: module}) do
    OpenApiSpex.Plug.PutApiSpec.call(conn, module)
  end
end
