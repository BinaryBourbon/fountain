defmodule FountainWeb.MovedController do
  @moduledoc """
  Where the retired browser pages send you (#867).

  `/conversations*`, `/team*` and `/onboarding*` were LiveViews. Watching an
  agent work and messaging a teammate now live in their own apps on the API
  (`Fountain.Apps`), and onboarding is the console's own first-run guidance,
  so those paths redirect rather than 404: links to them are in sent emails,
  in filed support issues, in agents' skills and in people's bookmarks.

  A 302, deliberately — a permanent redirect would be cached in browsers
  past any future change of mind. A deployment with no such app configured
  keeps the reader inside Fountain, on the dashboard.
  """
  use FountainWeb, :controller

  alias Fountain.Apps

  @doc "The conversations app's list."
  def conversations(conn, _params), do: away(conn, Apps.conversations())

  @doc "The conversations app's new-conversation screen."
  def new_conversation(conn, _params), do: away(conn, Apps.new_conversation_url())

  @doc "One conversation, or its raw log."
  def conversation(conn, %{"id" => id} = params) do
    away(conn, Apps.conversation_url(id, logs: params["logs"] == "logs"))
  end

  @doc "The team app's roster, or one teammate."
  def team(conn, params), do: away(conn, Apps.team_url(params["agent_id"]))

  @doc "Onboarding was a wizard; the console's dashboard is what greets a new account now."
  def onboarding(conn, _params), do: redirect(conn, to: ~p"/dashboard")

  defp away(conn, nil), do: redirect(conn, to: ~p"/dashboard")
  defp away(conn, url), do: redirect(conn, external: url)
end
