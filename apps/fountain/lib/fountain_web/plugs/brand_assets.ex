defmodule FountainWeb.Plugs.BrandAssets do
  @moduledoc """
  Lets the browser load the brand's icon and card from `BRAND_ASSETS_URL`.

  The `:browser` pipeline's policy allows images from `'self'` and `data:`
  only, which is right for the built-in files. A deployment that serves its
  bundle from another origin (`Fountain.Brand.assets_url/0`) needs that origin
  on `img-src`, and for the reason `FountainWeb.CSP` gives it is added here at
  runtime rather than in the router's attribute. With no bundle configured
  the header is untouched.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Fountain.Brand.assets_origin() do
      nil -> conn
      origin -> FountainWeb.CSP.widen(conn, ["img-src"], [origin])
    end
  end
end
