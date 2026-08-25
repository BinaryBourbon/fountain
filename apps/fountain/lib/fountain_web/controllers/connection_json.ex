defmodule FountainWeb.ConnectionJSON do
  @moduledoc "JSON views for connections (#1178). Never a token."

  alias Fountain.Connections.Connection

  def index(%{connections: connections}), do: %{data: Enum.map(connections, &summary/1)}

  def show(%{connection: c}), do: summary(c)

  def providers(%{providers: providers}), do: %{data: providers}

  defp summary(%Connection{} = c) do
    %{
      id: c.id,
      provider: c.provider,
      account_email: c.account_email,
      scopes: c.scopes,
      env_key: c.env_key,
      status: c.status,
      expires_at: c.expires_at,
      revoked_at: c.revoked_at,
      created_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end
end
