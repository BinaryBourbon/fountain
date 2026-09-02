defmodule Fountain.Resolver do
  @moduledoc false
  alias Fountain.{Error, HTTP}

  defstruct [:http, :cache]
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  def new(http) do
    cache = :ets.new(:fountain_resolver_cache, [:set, :public])
    %__MODULE__{http: http, cache: cache}
  end

  def clear(%__MODULE__{cache: cache}), do: :ets.delete_all_objects(cache)
  def forget(%__MODULE__{cache: cache}, path), do: :ets.delete(cache, path)

  def list(%__MODULE__{} = resolver, path) do
    case :ets.lookup(resolver.cache, path) do
      [{^path, items}] ->
        {:ok, items}

      [] ->
        case HTTP.list(resolver.http, path) do
          {:ok, items} ->
            :ets.insert(resolver.cache, {path, items})
            {:ok, items}

          error ->
            error
        end
    end
  end

  def resolve(%__MODULE__{} = resolver, path, what, value) do
    wanted = if is_binary(value), do: String.trim(value), else: ""

    cond do
      wanted == "" ->
        resolution_error("#{what} is required (a name or id)")

      Regex.match?(@uuid, wanted) ->
        {:ok, cached_by_id(resolver, path, wanted) || %{"id" => wanted}}

      true ->
        resolve_from_list(resolver, path, what, wanted)
    end
  end

  def resolve!(resolver, path, what, value) do
    case resolve(resolver, path, what, value) do
      {:ok, item} -> item
      {:error, error} -> raise error
    end
  end

  def resolve_id(_resolver, _path, _what, value) when value in [nil, ""], do: {:ok, nil}

  def resolve_id(resolver, path, what, value),
    do: with({:ok, item} <- resolve(resolver, path, what, value), do: {:ok, item["id"]})

  def resolve_id!(resolver, path, what, value) do
    case resolve_id(resolver, path, what, value) do
      {:ok, id} -> id
      {:error, error} -> raise error
    end
  end

  defp resolve_from_list(resolver, path, what, wanted) do
    with {:ok, items} <- list(resolver, path) do
      lower = String.downcase(wanted)
      by_id = Enum.filter(items, &(&1["id"] == wanted))
      exact = Enum.filter(items, &(String.downcase(&1["name"] || "") == lower))
      prefix = Enum.filter(items, &String.starts_with?(String.downcase(&1["name"] || ""), lower))

      case {by_id, exact, prefix} do
        {[item | _], _, _} ->
          {:ok, item}

        {_, [item], _} ->
          {:ok, item}

        {_, exact, _} when length(exact) > 1 ->
          resolution_error(
            "More than one #{what} is named #{inspect(wanted)}. Use the id: #{Enum.map_join(exact, ", ", & &1["id"])}"
          )

        {_, _, [item]} ->
          {:ok, item}

        {_, _, prefix} when length(prefix) > 1 ->
          resolution_error(
            "#{inspect(wanted)} matches more than one #{what}: #{Enum.map_join(prefix, ", ", &(&1["name"] || &1["id"]))}"
          )

        _ ->
          resolution_error(
            "No #{what} named #{inspect(wanted)}. On this account: #{describe(items)}"
          )
      end
    end
  end

  defp cached_by_id(resolver, path, id) do
    case :ets.lookup(resolver.cache, path) do
      [{^path, items}] -> Enum.find(items, fn item -> item["id"] == id end)
      [] -> nil
    end
  end

  defp describe([]), do: "(none)"

  defp describe(items),
    do: items |> Enum.map(&(&1["name"] || &1["id"])) |> Enum.sort() |> Enum.join(", ")

  defp resolution_error(message), do: {:error, %Error{message: message, kind: :resolution}}
end
