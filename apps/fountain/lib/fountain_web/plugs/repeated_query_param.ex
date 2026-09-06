defmodule FountainWeb.Plugs.RepeatedQueryParam do
  @moduledoc """
  Collect a repeated query key into a list, before the OpenAPI cast sees it.

  `?label=env:prod&label=drift:true` is one parameter sent twice, which is
  what OpenAPI calls `style: form, explode: true` and what an array parameter
  means on the wire. Two things get in the way:

    * `Plug.Conn.Query` collapses a repeated key to its **last** value, so
      `conn.params["label"]` is `"drift:true"` and the first filter is gone;
    * `OpenApiSpex.CastParameters` reads query parameters straight out of
      `Plug.Conn.fetch_query_params/1` and implements only the `explode:
      false` (comma-joined) form itself, so a parameter *declared* as an
      array would be handed that string and refuse it as "not an array" —
      turning a perfectly ordinary `?label=env:prod` into a 422.

  So the parameter cannot be declared honestly as an array until something
  reshapes it first, and that is this plug. It reads the raw query string,
  collects every occurrence of the named key, and writes the list back onto
  both `query_params` and `params` so the cast and the action see the same
  value. `name[]=` is collected too, for a client whose HTTP layer only knows
  how to build arrays that way.

  Declare it **before** `OpenApiSpex.Plug.CastAndValidate` in the controller,
  and scope it to the actions that take the parameter:

      plug FountainWeb.Plugs.RepeatedQueryParam, "label" when action in [:index]

  A request that sends the key once still arrives as a one-element list, so
  the action has one shape to read rather than two.
  """

  @behaviour Plug

  @impl Plug
  def init(name) when is_binary(name), do: name

  @impl Plug
  def call(%Plug.Conn{} = conn, name) do
    conn = Plug.Conn.fetch_query_params(conn)

    case collect(conn.query_string, name) do
      [] -> conn
      values -> put(conn, name, values)
    end
  end

  defp collect(query, name) when is_binary(query) do
    bracketed = name <> "[]"

    for {key, value} <- URI.query_decoder(query), key in [name, bracketed], do: value
  end

  defp collect(_query, _name), do: []

  defp put(conn, name, values) do
    %{
      conn
      | query_params: Map.put(conn.query_params, name, values),
        params: put_param(conn.params, name, values)
    }
  end

  # `params` is `%Plug.Conn.Unfetched{}` until the body parsers have run. Every
  # route this plug is on has run them, but reshaping an unfetched struct into
  # a map would quietly swallow the body, so leave it alone and let
  # `query_params` carry the value.
  defp put_param(%Plug.Conn.Unfetched{} = params, _name, _values), do: params
  defp put_param(params, name, values) when is_map(params), do: Map.put(params, name, values)
end
