defmodule Fountain.Resources.Collection do
  @moduledoc false
  alias Fountain.{HTTP, Resolver}

  def list(resource, search \\ nil),
    do: HTTP.list(resource.http, resource.path, query: [search: search])

  def get(resource, name_or_id) do
    with {:ok, item} <-
           Resolver.resolve(resource.resolver, resource.path, resource.what, name_or_id),
         do: HTTP.data(resource.http, "GET", "#{resource.path}/#{item["id"]}")
  end

  def create(resource, input) do
    with {:ok, value} <- HTTP.data(resource.http, "POST", resource.path, body: input) do
      Resolver.forget(resource.resolver, resource.path)
      {:ok, value}
    end
  end

  def update(resource, name_or_id, patch) do
    with {:ok, item} <-
           Resolver.resolve(resource.resolver, resource.path, resource.what, name_or_id),
         {:ok, value} <-
           HTTP.data(resource.http, "PATCH", "#{resource.path}/#{item["id"]}", body: patch) do
      Resolver.forget(resource.resolver, resource.path)
      {:ok, value}
    end
  end

  def delete(resource, name_or_id) do
    with {:ok, item} <-
           Resolver.resolve(resource.resolver, resource.path, resource.what, name_or_id),
         {:ok, _} <- HTTP.request(resource.http, "DELETE", "#{resource.path}/#{item["id"]}") do
      Resolver.forget(resource.resolver, resource.path)
      :ok
    end
  end
end

defmodule Fountain.Agents do
  @moduledoc "CRUD operations for agent definitions."
  defstruct [:http, :resolver, path: "/api/agents", what: "agent"]
  def new(http, resolver), do: %__MODULE__{http: http, resolver: resolver}
  def list(agents, search \\ nil), do: Fountain.Resources.Collection.list(agents, search)
  def get(agents, name_or_id), do: Fountain.Resources.Collection.get(agents, name_or_id)
  def create(agents, input), do: Fountain.Resources.Collection.create(agents, input)

  def update(agents, name_or_id, patch),
    do: Fountain.Resources.Collection.update(agents, name_or_id, patch)

  def delete(agents, name_or_id), do: Fountain.Resources.Collection.delete(agents, name_or_id)
end

defmodule Fountain.Secrets do
  @moduledoc "Write-only secrets attached to an environment or vault."
  alias Fountain.{HTTP, Resolver}
  defstruct [:http, :resolver, :parent_path, :what]

  def list(secrets, parent),
    do:
      with(
        {:ok, base} <- parent_path(secrets, parent),
        do: HTTP.list(secrets.http, "#{base}/secrets")
      )

  def set(secrets, parent, key, value),
    do:
      with(
        {:ok, base} <- parent_path(secrets, parent),
        do:
          HTTP.data(secrets.http, "POST", "#{base}/secrets",
            body: %{"key" => key, "value" => value}
          )
      )

  def set_all(secrets, parent, values) do
    Enum.reduce_while(values, {:ok, []}, fn {key, value}, {:ok, result} ->
      case set(secrets, parent, to_string(key), value) do
        {:ok, item} -> {:cont, {:ok, [item | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  def delete(secrets, parent, key) do
    with {:ok, base} <- parent_path(secrets, parent),
         {:ok, _} <-
           HTTP.request(
             secrets.http,
             "DELETE",
             "#{base}/secrets/#{URI.encode(to_string(key), &URI.char_unreserved?/1)}"
           ),
         do: :ok
  end

  defp parent_path(secrets, parent) do
    with {:ok, item} <-
           Resolver.resolve(secrets.resolver, secrets.parent_path, secrets.what, parent),
         do: {:ok, "#{secrets.parent_path}/#{item["id"]}"}
  end
end

defmodule Fountain.Environments do
  @moduledoc "CRUD operations for environments and their secrets."
  defstruct [:http, :resolver, :secrets, path: "/api/environments", what: "environment"]

  def new(http, resolver),
    do: %__MODULE__{
      http: http,
      resolver: resolver,
      secrets: %Fountain.Secrets{
        http: http,
        resolver: resolver,
        parent_path: "/api/environments",
        what: "environment"
      }
    }

  def list(value, search \\ nil), do: Fountain.Resources.Collection.list(value, search)
  def get(value, name_or_id), do: Fountain.Resources.Collection.get(value, name_or_id)
  def create(value, input), do: Fountain.Resources.Collection.create(value, input)

  def update(value, name_or_id, patch),
    do: Fountain.Resources.Collection.update(value, name_or_id, patch)

  def delete(value, name_or_id), do: Fountain.Resources.Collection.delete(value, name_or_id)
end

defmodule Fountain.Vaults do
  @moduledoc "CRUD operations for vaults and their secrets."
  defstruct [:http, :resolver, :secrets, path: "/api/vaults", what: "vault"]

  def new(http, resolver),
    do: %__MODULE__{
      http: http,
      resolver: resolver,
      secrets: %Fountain.Secrets{
        http: http,
        resolver: resolver,
        parent_path: "/api/vaults",
        what: "vault"
      }
    }

  def list(value, search \\ nil), do: Fountain.Resources.Collection.list(value, search)
  def get(value, name_or_id), do: Fountain.Resources.Collection.get(value, name_or_id)
  def create(value, input), do: Fountain.Resources.Collection.create(value, input)

  def update(value, name_or_id, patch),
    do: Fountain.Resources.Collection.update(value, name_or_id, patch)

  def delete(value, name_or_id), do: Fountain.Resources.Collection.delete(value, name_or_id)
end

defmodule Fountain.Connections do
  @moduledoc "Provider connections whose credentials Fountain holds."
  alias Fountain.HTTP
  defstruct [:http, :providers]

  def new(http),
    do: %__MODULE__{http: http, providers: struct(Fountain.ConnectionProviders, http: http)}

  def list(value), do: HTTP.list(value.http, "/api/connections")
  def get(value, id), do: HTTP.request(value.http, "GET", "/api/connections/#{escape(id)}")

  def delete(value, id) do
    case HTTP.request(value.http, "DELETE", "/api/connections/#{escape(id)}") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp escape(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end

defmodule Fountain.ConnectionProviders do
  @moduledoc "OAuth and MCP connection provider definitions."
  alias Fountain.HTTP
  defstruct [:http]
  def list(value), do: HTTP.list(value.http, "/api/connection-providers")

  def get(value, id),
    do: HTTP.request(value.http, "GET", "/api/connection-providers/#{escape(id)}")

  def create(value, input),
    do: HTTP.request(value.http, "POST", "/api/connection-providers", body: input)

  def update(value, id, patch),
    do: HTTP.request(value.http, "PATCH", "/api/connection-providers/#{escape(id)}", body: patch)

  def delete(value, id) do
    case HTTP.request(value.http, "DELETE", "/api/connection-providers/#{escape(id)}") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def discover(value, id),
    do: HTTP.request(value.http, "POST", "/api/connection-providers/#{escape(id)}/discover")

  defp escape(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
