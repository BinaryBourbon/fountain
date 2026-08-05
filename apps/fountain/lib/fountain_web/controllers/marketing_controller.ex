defmodule FountainWeb.MarketingController do
  @moduledoc false
  use FountainWeb, :controller

  # Placeholders for the legal pages, kept in one place so filling them is a
  # single edit. They must be replaced with real values before charging
  # customers — a page that says {{COMPANY_LEGAL_NAME}} is deliberately loud.
  @legal %{
    entity: "{{COMPANY_LEGAL_NAME}}",
    contact_email: "{{CONTACT_EMAIL}}",
    jurisdiction: "{{JURISDICTION}}",
    updated: "{{EFFECTIVE_DATE}}"
  }

  def home(conn, _params) do
    render(conn, :home, layout: {FountainWeb.Layouts, :marketing})
  end

  def terms(conn, _params) do
    render(conn, :terms, layout: {FountainWeb.Layouts, :marketing}, legal: @legal)
  end

  def privacy(conn, _params) do
    render(conn, :privacy, layout: {FountainWeb.Layouts, :marketing}, legal: @legal)
  end
end
