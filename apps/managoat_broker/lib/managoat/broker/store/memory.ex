defmodule Managoat.Broker.Store.Memory do
  @moduledoc """
  The reference `Managoat.Broker.Store`: sessions in an `Agent`, keyed by
  token.

  For the library's own tests and for a consumer without a database. Start
  one per listener (`{Managoat.Broker.Store.Memory, name: MyStore}`) and
  point the listener at it with `store: {Managoat.Broker.Store.Memory,
  MyStore}`; or start it under its default name and use the bare module.

  Tokens are stored as given. A store that persists them should hash first
  (`Managoat.Broker.Store` says why that is the host's choice).
  """

  @behaviour Managoat.Broker.Store

  use Agent

  alias Managoat.Broker.Session

  @doc "Start a store. `name:` defaults to this module."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Bind `token` to `session`. Replaces an existing binding."
  @spec put(Agent.agent(), binary(), Session.t()) :: :ok
  def put(store \\ __MODULE__, token, %Session{} = session) when is_binary(token) do
    Agent.update(store, &Map.put(&1, token, session))
  end

  @doc "Forget `token`."
  @spec delete(Agent.agent(), binary()) :: :ok
  def delete(store \\ __MODULE__, token) when is_binary(token) do
    Agent.update(store, &Map.delete(&1, token))
  end

  @doc "Every token the store holds."
  @spec tokens(Agent.agent()) :: [binary()]
  def tokens(store \\ __MODULE__), do: Agent.get(store, &Map.keys/1)

  @doc "Mint a random token (`mb_` + 43 url-safe base64 characters)."
  @spec generate_token() :: binary()
  def generate_token,
    do: "mb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @impl Managoat.Broker.Store
  def lookup(token), do: lookup(__MODULE__, token)

  @impl Managoat.Broker.Store
  def lookup(store, token) when is_binary(token) do
    case Agent.get(store, &Map.fetch(&1, token)) do
      {:ok, %Session{} = session} -> {:ok, session}
      :error -> :error
    end
  end
end
