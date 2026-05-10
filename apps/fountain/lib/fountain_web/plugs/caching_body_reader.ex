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
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = put_in(conn.assigns[:raw_body], body)
    {:ok, body, conn}
  end
end
