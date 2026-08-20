defmodule Fountain.Apps do
  @moduledoc """
  Where the browser apps that sit on Fountain's API live.

  Fountain's own UI is a console — accounts, keys, agents, environments,
  vaults, audit, admin. Watching an agent work and messaging a teammate are
  separate single-page apps on their own origins, talking to `/api` with a
  bearer key (ADR 0021 gave them "Sign in with Fountain"). This module is the
  one place that knows their URLs, so the console's links, an email's
  "open it" and a forwarded support report all agree.

  Both default to the apps hosted at jakegaylor.com. They are ordinary static
  builds with **no server of their own**: the reader types their Fountain's
  URL in, so the hosted build works against a self-hosted Fountain as soon as
  that server admits the origin:

      API_CORS_ORIGINS=https://jakegaylor.com

  A deployment that would rather host its own copy points `CONVERSATIONS_APP_URL`
  and `TEAM_APP_URL` at it (and admits *that* origin instead). Setting either
  to an empty string says "this deployment has no such app": the console stops
  linking to it, and the retired in-app routes redirect to the dashboard
  rather than off-site.
  """

  @conversations "https://jakegaylor.com/fountain-conversations/"
  @team "https://jakegaylor.com/fountain-team/"

  @doc "The conversations app's base URL, or nil where the deployment has none."
  @spec conversations() :: String.t() | nil
  def conversations, do: get(:conversations_app_url, @conversations)

  @doc "The team app's base URL, or nil where the deployment has none."
  @spec team() :: String.t() | nil
  def team, do: get(:team_app_url, @team)

  @doc """
  A deep link into the conversations app, or nil when there is no app.

  The app routes on the fragment, so a conversation is `#/c/<id>` and its raw
  log `#/c/<id>/logs`.

      iex> Fountain.Apps.conversation_url("abc")
      "https://jakegaylor.com/fountain-conversations/#/c/abc"
  """
  @spec conversation_url(String.t(), keyword()) :: String.t() | nil
  def conversation_url(id, opts \\ []) when is_binary(id) do
    case conversations() do
      nil -> nil
      base -> base <> "#/c/" <> id <> if(opts[:logs], do: "/logs", else: "")
    end
  end

  @doc "The conversations app's new-conversation screen, or nil."
  @spec new_conversation_url() :: String.t() | nil
  def new_conversation_url do
    case conversations() do
      nil -> nil
      base -> base <> "#/new"
    end
  end

  @doc """
  A deep link to one teammate in the team app, or the roster when no id is
  given. nil where the deployment has no team app.
  """
  @spec team_url(String.t() | nil) :: String.t() | nil
  def team_url(agent_id \\ nil) do
    case {team(), agent_id} do
      {nil, _} -> nil
      {base, nil} -> base
      {base, id} -> base <> "#/team/" <> id
    end
  end

  # An unset key takes the default; an explicitly empty one means "none", which
  # is how a deployment turns a link off rather than pointing it somewhere wrong.
  defp get(key, default) do
    case Application.get_env(:fountain, key, default) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> String.trim_trailing(value, "/") <> "/"
    end
  end
end
