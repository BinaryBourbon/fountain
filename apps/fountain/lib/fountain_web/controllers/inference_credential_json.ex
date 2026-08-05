defmodule FountainWeb.InferenceCredentialJSON do
  @moduledoc false

  def index(%{status: status, providers: providers}) do
    %{data: Enum.map(providers, &provider_json(&1, status))}
  end

  def show(%{provider: provider, status: status}) do
    %{data: provider_json(provider, status)}
  end

  defp provider_json(provider, status) do
    %{provider: Atom.to_string(provider), set: Map.get(status, provider, false)}
  end
end
