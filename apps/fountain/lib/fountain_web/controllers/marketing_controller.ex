defmodule FountainWeb.MarketingController do
  @moduledoc false
  use FountainWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: {FountainWeb.Layouts, :marketing})
  end
end
