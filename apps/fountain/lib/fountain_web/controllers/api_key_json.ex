defmodule FountainWeb.ApiKeyJSON do
  @moduledoc "JSON views for API key responses."

  alias Fountain.Accounts.ApiKey

  @doc "Response for key creation — includes the raw key (shown once only)."
  def created(%{key: %ApiKey{} = key, raw_key: raw_key}) do
    %{
      id: key.id,
      name: key.name,
      key: raw_key,
      prefix: key.key_prefix,
      created_at: key.inserted_at
    }
  end

  @doc "Key listing — metadata only, never the key or its hash."
  def index(%{keys: keys}), do: %{data: Enum.map(keys, &summary/1)}

  defp summary(%ApiKey{} = key) do
    %{
      id: key.id,
      name: key.name,
      prefix: key.key_prefix,
      created_at: key.inserted_at,
      last_used_at: key.last_used_at
    }
  end
end
