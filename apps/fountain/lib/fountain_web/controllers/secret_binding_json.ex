defmodule FountainWeb.SecretBindingJSON do
  @moduledoc "JSON views for secret bindings (ADR 0019 gate 1b)."

  alias Fountain.SecretBindings.Binding

  def index(%{bindings: bindings}), do: %{data: Enum.map(bindings, &summary/1)}

  def show(%{binding: b}), do: summary(b)

  def presets(%{presets: presets}), do: %{data: Enum.map(presets, &preset/1)}

  defp summary(%Binding{} = b) do
    %{
      id: b.id,
      key: b.key,
      host: b.host,
      auth_type: b.auth_type,
      header: b.header,
      prefix: b.prefix,
      username: b.username,
      headers: b.headers,
      enabled: b.enabled,
      created_at: b.inserted_at,
      updated_at: b.updated_at
    }
  end

  defp preset(p) do
    %{
      id: p.id,
      name: p.name,
      host: p.host,
      description: p.description,
      auth_type: p.auth_type,
      suggested_key: p.suggested_key,
      header: p.header,
      prefix: p.prefix,
      headers: p.headers,
      usable: p.usable
    }
  end
end
