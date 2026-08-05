defmodule FountainWeb.AccountDataJSON do
  @moduledoc false

  alias Fountain.Exports.Export

  def index_exports(%{exports: exports}), do: %{data: Enum.map(exports, &data/1)}
  def show_export(%{export: export}), do: %{data: data(export)}

  defp data(%Export{} = e) do
    %{
      id: e.id,
      status: e.status,
      byte_size: e.byte_size,
      error: e.error,
      expires_at: e.expires_at,
      # The payload is never serialized here — it is downloaded, not embedded.
      downloadable: e.status == "completed" and not Fountain.Exports.expired?(e),
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end
end
