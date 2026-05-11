defmodule FountainWeb.VaultSecretJSON do
  @moduledoc false
  alias Fountain.Vaults.VaultSecret

  def index(%{secrets: secrets}), do: %{data: Enum.map(secrets, &data/1)}
  def show(%{secret: secret}), do: %{data: data(secret)}

  # Values are never returned over the API once stored.
  def data(%VaultSecret{} = s) do
    %{
      id: s.id,
      key: s.key,
      vault_id: s.vault_id,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end
end
