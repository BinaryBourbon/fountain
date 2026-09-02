defmodule Managoat.Broker.Store do
  @moduledoc """
  The one thing the proxy needs from the host at request time: a session
  for a token.

  A sandbox dials the proxy with `Proxy-Authorization: Basic
  base64(token:label)`. The proxy hands the raw `token` to the store and
  serves the connection under the `Managoat.Broker.Session` it gets back,
  or refuses it with 407. Everything else about sessions (creating one,
  hashing the token before storing it, encrypting the rules, releasing a
  conversation's sessions, sweeping expired rows) is the host's business:
  it touches the host's tables and its key hierarchy, and the proxy never
  needs any of it.

  The `label` half of the credential is not passed on. It exists because
  some clients (git) refuse a proxy URL with a user and no password; with a
  random per-session token the token alone is the binding.

  ## Configuring the store

  The listener's `store:` option is either a module implementing this
  behaviour, called as `module.lookup(token)`, or a `{module, instance}`
  pair, called as `module.lookup(instance, token)` for a store that has
  several instances (the in-memory store in a test, one per listener).

  `Managoat.Broker.Store.Memory` is the reference store: an in-memory map,
  for tests and for a consumer without a database.
  """

  alias Managoat.Broker.Session

  @doc "The session for a raw token, or `:error` for a token the store does not know."
  @callback lookup(token :: binary()) :: {:ok, Session.t()} | :error

  @doc "The same, for a store with several instances (see the moduledoc)."
  @callback lookup(instance :: term(), token :: binary()) :: {:ok, Session.t()} | :error

  @optional_callbacks lookup: 1, lookup: 2

  @typedoc "What the listener's `store:` option accepts."
  @type ref :: module() | {module(), term()}

  @doc false
  @spec lookup(ref(), binary()) :: {:ok, Session.t()} | :error
  def lookup(module, token) when is_atom(module), do: module.lookup(token)
  def lookup({module, instance}, token) when is_atom(module), do: module.lookup(instance, token)
end
