defmodule FountainWeb.CachingBodyReader do
  @moduledoc """
  Custom `body_reader` for `Plug.Parsers` that caches the raw request body in
  `conn.assigns[:raw_body]` before the parser consumes it.

  Required by `FountainWeb.StripeWebhookController` to verify Stripe webhook
  signatures, which must be computed over the exact unmodified request body.

  ## Configuration (in FountainWeb.Endpoint)

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library(),
        body_reader: {FountainWeb.CachingBodyReader, :read_body, []}
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    # Every branch has to be passed through. This used to hard-match
    # `{:ok, body, conn}`, so a request larger than the parser's read length —
    # where `Plug.Conn.read_body/2` returns `{:more, ...}` — raised a MatchError
    # and surfaced as a 500 on every endpoint, instead of the 413 that
    # `Plug.Parsers` produces when it is told the body did not fit. An
    # oversized upload is a client error and should read as one.
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, put_in(conn.assigns[:raw_body], body)}

      {:more, partial, conn} ->
        # Deliberately not cached: a partial body would let the Stripe webhook
        # verifier compute a signature over something that was never sent.
        {:more, partial, conn}

      {:error, _} = err ->
        err
    end
  end
end
