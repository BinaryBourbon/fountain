defmodule FountainWeb.OAuthClientJSON do
  @moduledoc "JSON views for tenant-registered OAuth clients (#1125)."

  alias Fountain.OAuth.Client

  def index(%{clients: clients}), do: %{data: Enum.map(clients, &summary/1)}

  def show(%{client: client}), do: summary(client)

  # `origins` is derived rather than the stored lookup key, so a caller sees
  # the origins it will actually be calling `/api` from.
  defp summary(%Client{} = c) do
    %{
      id: c.id,
      client_id: c.client_id,
      name: c.name,
      redirect_uris: c.redirect_uris,
      origins: Client.origins_of(c.redirect_uris),
      published: c.published,
      created_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end
end
