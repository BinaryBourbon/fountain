defmodule Managoat.Broker.Session do
  @moduledoc """
  What a proxy token resolves to: the rules the proxy may apply, what to do
  with a host no rule names, when the token stops working, and an opaque
  `meta` the host fills for its own logging.

  A `Managoat.Broker.Store` returns one of these from `lookup/1` with the
  credentials inside `rules` already decrypted. How it is stored, hashed,
  encrypted or swept is the store's business; the proxy looks a token up
  once per client connection, which is the unit a sandbox's HTTP client
  pools on.

  `meta` travels unchanged into every `[:managoat, :broker, :request]`
  telemetry event for a request served under the session, so a host that
  puts a conversation id and a user id there gets them back on each log
  line without the library knowing what either is.
  """

  alias Managoat.Broker.Rule

  @type policy :: :passthrough | :deny

  @type t :: %__MODULE__{
          rules: [Rule.t()],
          unmatched_host_policy: policy(),
          expires_at: DateTime.t() | nil,
          meta: map()
        }

  defstruct rules: [], unmatched_host_policy: :passthrough, expires_at: nil, meta: %{}

  @doc "True when `expires_at` is set and in the past."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) == :lt
end
