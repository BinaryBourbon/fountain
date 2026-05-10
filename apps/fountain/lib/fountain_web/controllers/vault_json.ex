defmodule FountainWeb.VaultJSON do
  alias Fountain.Vaults.Vault

  def index(%{vaults: vaults}), do: %{data: Enum.map(vaults, &data/1)}
  def show(%{vault: vault}), do: %{data: data(vault)}

  def data(%Vault{} = v) do
    %{
      id: v.id,
      name: v.name,
      description: v.description,
      inserted_at: v.inserted_at,
      updated_at: v.updated_at
    }
  end
end
