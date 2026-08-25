defmodule Fountain.Connections.Google do
  @moduledoc """
  The one platform provider (#1178, #1186): Google, from Fountain's own OAuth
  client (`GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`). Since
  #1186 the OAuth flow itself is `Fountain.Connections.OAuth`, driven by the
  `Fountain.Connections.Provider` struct `provider/0` builds from config;
  this module is the handful of facts the console and the catalog ask for.

  Unset, `configured?/0` is false and the console shows the feature as not
  available on this deployment.
  """

  alias Fountain.Connections.{OAuth, Provider}

  def provider, do: Provider.google()

  def slug, do: "google"
  def scopes, do: provider().scopes
  def token_hosts, do: provider().token_hosts

  @doc "The env var name a Google connection's access token is brokered under."
  def env_key, do: provider().env_key

  @doc "True when both halves of the OAuth client are set."
  def configured?, do: OAuth.configured?(provider())
end
