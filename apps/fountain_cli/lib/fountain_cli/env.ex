defmodule FountainCli.Env do
  @moduledoc false

  alias FountainCli.Api

  def dispatch(["list" | rest]), do: list(rest)
  def dispatch(["show", id | _]), do: show(id)
  def dispatch(_), do: FountainCli.die("unknown env command")

  defp list(args) do
    json? = "--json" in args
    {:ok, %{"data" => envs}} = Api.get("/environments")

    if json? do
      IO.puts(Jason.encode!(envs, pretty: true))
    else
      print_table(
        ["name", "networking", "setup_script"],
        Enum.map(envs, fn e ->
          [e["name"], e["networking_type"], truncate(e["setup_script"], 60)]
        end)
      )
    end
  end

  defp show(id) do
    {:ok, %{"data" => e}} = Api.get("/environments/#{id}")
    {:ok, %{"data" => secrets}} = Api.get("/environments/#{id}/secrets")
    IO.puts(Jason.encode!(Map.put(e, "secrets", secrets), pretty: true))
  end

  defp truncate(nil, _), do: ""
  defp truncate(s, n) when is_binary(s) and byte_size(s) > n, do: binary_part(s, 0, n) <> "…"
  defp truncate(s, _), do: s

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
