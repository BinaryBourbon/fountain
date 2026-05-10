defmodule FountainCli.Vault do
  @moduledoc false

  alias FountainCli.Api

  def dispatch(["list" | rest]), do: list(rest)
  def dispatch(["show", id | _]), do: show(id)
  def dispatch(["create", name | rest]), do: create(name, rest)
  def dispatch(["delete", id | _]), do: delete(id)
  def dispatch(["set-secret", id, key, value | _]), do: set_secret(id, key, value)
  def dispatch(["delete-secret", id, key | _]), do: delete_secret(id, key)
  def dispatch(_), do: FountainCli.die("unknown vault command")

  defp list(args) do
    json? = "--json" in args
    {:ok, %{"data" => vaults}} = Api.get("/vaults")

    if json? do
      IO.puts(Jason.encode!(vaults, pretty: true))
    else
      print_table(
        ["name", "id", "description"],
        Enum.map(vaults, fn v ->
          [v["name"], short(v["id"]), truncate(v["description"], 60)]
        end)
      )
    end
  end

  defp show(target) do
    id = resolve_id(target)
    {:ok, %{"data" => v}} = Api.get("/vaults/#{id}")
    {:ok, %{"data" => secrets}} = Api.get("/vaults/#{id}/secrets")
    IO.puts(Jason.encode!(Map.put(v, "secrets", secrets), pretty: true))
  end

  defp create(name, args) do
    {opts, _, _} = OptionParser.parse(args, strict: [description: :string])
    body = %{name: name, description: opts[:description] || ""}

    case Api.post("/vaults", body) do
      {:ok, %{"data" => v}} -> IO.puts("vault  +  #{v["name"]} (#{v["id"]})")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  defp delete(target) do
    id = resolve_id(target)

    case Api.delete("/vaults/#{id}") do
      {:ok, _} -> IO.puts("deleted #{id}")
      {:error, {404, _}} -> FountainCli.die("not found")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  defp set_secret(target, key, value) do
    id = resolve_id(target)

    case Api.post("/vaults/#{id}/secrets", %{key: key, value: value}) do
      {:ok, _} -> IO.puts("secret  +  #{key}")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  defp delete_secret(target, key) do
    id = resolve_id(target)

    case Api.delete("/vaults/#{id}/secrets/#{key}") do
      {:ok, _} -> IO.puts("deleted secret #{key}")
      {:error, {404, _}} -> FountainCli.die("not found")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  @doc false
  def resolve_id(target) do
    if uuid?(target) do
      target
    else
      {:ok, %{"data" => vaults}} = Api.get("/vaults")

      case Enum.find(vaults, &(&1["name"] == target)) do
        nil -> FountainCli.die("no vault named #{inspect(target)}")
        v -> v["id"]
      end
    end
  end

  defp uuid?(s), do: String.match?(s, ~r/^[0-9a-f-]{36}$/i)

  defp truncate(nil, _), do: ""
  defp truncate(s, n) when is_binary(s) and byte_size(s) > n, do: binary_part(s, 0, n) <> "…"
  defp truncate(s, _), do: s

  defp short(nil), do: ""
  defp short(s) when is_binary(s) and byte_size(s) >= 8, do: binary_part(s, 0, 8)
  defp short(s), do: s

  defp print_table(headers, rows) do
    widths =
      Enum.with_index(headers, fn h, i ->
        [to_string(h) | Enum.map(rows, fn r -> to_string(Enum.at(r, i) || "") end)]
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    IO.puts(
      headers
      |> Enum.with_index()
      |> Enum.map_join("  ", fn {h, i} ->
        String.pad_trailing(to_string(h), Enum.at(widths, i))
      end)
    )

    IO.puts(Enum.map_join(widths, "  ", &String.duplicate("-", &1)))

    for r <- rows do
      IO.puts(
        r
        |> Enum.with_index()
        |> Enum.map_join("  ", fn {v, i} ->
          String.pad_trailing(to_string(v || ""), Enum.at(widths, i))
        end)
      )
    end
  end
end
