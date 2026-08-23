defmodule FountainWeb.MarketingController do
  @moduledoc """
  The public pages: `/`, `/terms` and `/privacy`.

  None of the three is the same page on every deployment. `/` serves the
  product pitch on the marketing site and a plain front door everywhere else
  (`Fountain.Marketing`); the legal pages render the operator's identity, or
  nothing at all (`Fountain.Legal`). A deployment is not the Fountain project,
  and these pages are the three that would claim otherwise.
  """
  use FountainWeb, :controller

  def home(conn, _params) do
    page = if Fountain.Marketing.site?(), do: :home, else: :instance
    render(conn, page, layout: {FountainWeb.Layouts, :marketing})
  end

  def terms(conn, _params) do
    render_legal(conn, :terms)
  end

  def privacy(conn, _params) do
    render_legal(conn, :privacy)
  end

  # The legal identity is the operator's, set via LEGAL_* env vars (#517) —
  # see Fountain.Legal for the unconfigured behaviour (neutral 404 on a
  # billing-disabled instance, loud placeholders on a billing-enabled one).
  defp render_legal(conn, page) do
    case Fountain.Legal.content() do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:legal_unpublished, layout: {FountainWeb.Layouts, :marketing})

      legal ->
        render(conn, page, layout: {FountainWeb.Layouts, :marketing}, legal: legal)
    end
  end
end
