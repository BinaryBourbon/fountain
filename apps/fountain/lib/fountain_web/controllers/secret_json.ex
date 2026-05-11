defmodule FountainWeb.SecretJSON do
  @moduledoc false
  alias Fountain.Environments.Secret

  def index(%{secrets: secrets}), do: %{data: Enum.map(secrets, &data/1)}
  def show(%{secret: secret}), do: %{data: data(secret)}

  # Values are never returned over the API once stored.
  def data(%Secret{} = s) do
    %{
      id: s.id,
      key: s.key,
      environment_id: s.environment_id,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end
end
