defmodule FountainCli.Agent do
  @moduledoc false

  alias FountainCli.Api

  def dispatch(["list" | rest]), do: list(rest)
  def dispatch(["show", id | _]), do: show(id)
  def dispatch(_), do: FountainCli.die("unknown agent command")

  defp list(args) do
    json? = "--json" in args
    {:ok, %{"data" => agents}} = Api.get("/agents")

    if json? do
      IO.puts(Jason.encode!(agents, pretty: true))
    else
      print_table(
        ["name", "runtime", "model", "env"],
        Enum.map(agents, fn a ->
          [a["name"], a["runtime"], a["model"], short(a["environment_id"])]
        end)
      )
    end
  end

  defp show(id) do
    {:ok, %{"data" => a}} = Api.get("/agents/#{id}")
    IO.puts(Jason.encode!(a, pretty: true))
  end

  defp short(nil), do: "(none)"
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
