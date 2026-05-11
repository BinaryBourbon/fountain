defmodule FountainWeb.MarketingController do
  @moduledoc false
  use FountainWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/dashboard")
    else
      render(conn, :home, layout: {FountainWeb.Layouts, :marketing})
    end
  end
end
