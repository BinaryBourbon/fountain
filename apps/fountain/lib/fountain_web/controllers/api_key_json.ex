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
end
