defmodule FountainCli.Keys do
  @moduledoc """
  Subcommands for managing Fountain API keys.

      fountain keys list
          Lists API keys: prefix, name, last_used_at.

      fountain keys create <name>
          Creates a new API key and prints the plaintext key once.

      fountain keys revoke <id>
          Revokes the key with the given id (confirmation required).
  """

  alias FountainCli.Api

  def dispatch(["list" | rest]), do: list(rest)
  def dispatch(["create", name | rest]), do: create(name, rest)
  def dispatch(["revoke", id | rest]), do: revoke(id, rest)

  def dispatch(["create" | _]) do
    FountainCli.die("usage: fountain keys create <name>")
  end

  def dispatch(["revoke" | _]) do
    FountainCli.die("usage: fountain keys revoke <id>")
  end

  def dispatch(args) do
    FountainCli.die(
      "unknown keys command: #{Enum.join(args, " ")}\n" <>
        "Available: list, create <name>, revoke <id>"
    )
  end

  # ── list ─────────────────────────────────────────────────

  defp list(_args) do
    case Api.get("/auth/api-keys") do
      {:ok, %{"data" => keys}} when is_list(keys) ->
        print_table(
          ["prefix", "name", "last_used"],
          Enum.map(keys, fn k ->
            [k["key_prefix"], k["name"], k["last_used_at"] || "never"]
          end)
        )

      {:ok, other} ->
        FountainCli.die("unexpected response: #{inspect(other)}")

      {:error, e} ->
        FountainCli.die(inspect(e))
    end
  end

  # ── create ───────────────────────────────────────────────

  defp create(name, _args) do
    case Api.post("/auth/api-keys", %{name: name}) do
      {:ok, %{"data" => %{"key" => key} = k}} ->
        IO.puts("""

        ╭────────────────────────────────────────────────────────────────╮
        │  Save this key — it will not be shown again.                  │
        ╰────────────────────────────────────────────────────────────────╯

        #{key}

        Name:   #{k["name"]}
        Prefix: #{k["key_prefix"]}
        """)

      {:ok, other} ->
        FountainCli.die("unexpected response: #{inspect(other)}")

      {:error, e} ->
        FountainCli.die(inspect(e))
    end
  end

  # ── revoke ──────────────────────────────────────────────

  defp revoke(id, _args) do
    IO.write("Revoke API key #{id}? This cannot be undone. [y/N] ")
    confirm = IO.gets("") |> String.trim() |> String.downcase()

    if confirm in ["y", "yes"] do
      case Api.delete("/auth/api-keys/#{id}") do
        {:ok, _} ->
          IO.puts("Revoked #{id}.")

        {:error, {404, _}} ->
          FountainCli.die("key not found: #{id}")

        {:error, e} ->
          FountainCli.die(inspect(e))
      end
    else
      IO.puts("Aborted.")
    end
  end

  # ── shared helpers ───────────────────────────────────────────

  defp print_table(headers, rows) do
    widths =
      Enum.with_index(headers, fn h, i ->
        [to_string(h) | Enum.map(rows, fn r -> to_string(Enum.at(r, i) || "") end)]
        |> Enum.map(&String.length/1)
        |> Enum.max(fn -> 0 end)
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
