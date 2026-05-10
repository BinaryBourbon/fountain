defmodule FountainCli.Conv do
  @moduledoc false

  alias FountainCli.Api

  def dispatch(["list" | rest]), do: list(rest)
  def dispatch(["show", id | _]), do: show(id)
  def dispatch(["stream", id | _]), do: stream(id)
  def dispatch(["prompt", id | rest]), do: prompt(id, rest)
  def dispatch(["interrupt", id | _]), do: interrupt(id)
  def dispatch(["terminate", id | _]), do: terminate(id)
  def dispatch(["delete", id | _]), do: delete(id)
  def dispatch(_), do: FountainCli.die("unknown conv command")

  # ── run: start + stream + wait for turn end ──────────────────────────────

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [prompt: :string, vault: :string],
        aliases: [p: :prompt]
      )

    [target | _] = positional ++ [nil]
    target || FountainCli.die("usage: aod run <agent-name-or-id> -p \"<prompt>\" [--vault <name|id>]")
    prompt_text = opts[:prompt] || FountainCli.die("missing -p <prompt>")

    agent_id = resolve_agent(target)

    body =
      %{agent_id: agent_id, prompt: prompt_text}
      |> maybe_put_vault(opts[:vault])

    {:ok, %{"data" => conv}} = Api.post("/conversations", body)

    IO.puts(:stderr, "▸ conversation #{conv["id"]}")
    follow_until_idle(conv["id"])
  end

  defp maybe_put_vault(body, nil), do: body
  defp maybe_put_vault(body, ""), do: body

  defp maybe_put_vault(body, target),
    do: Map.put(body, :vault_id, FountainCli.Vault.resolve_id(target))

  defp resolve_agent(target) do
    if uuid?(target) do
      target
    else
      {:ok, %{"data" => agents}} = Api.get("/agents")

      case Enum.find(agents, &(&1["name"] == target)) do
        nil -> FountainCli.die("no agent named #{inspect(target)}")
        a -> a["id"]
      end
    end
  end

  defp uuid?(s), do: String.match?(s, ~r/^[0-9a-f-]{36}$/i)

  defp follow_until_idle(conv_id) do
    Api.stream("/conversations/#{conv_id}/stream", &handle_event/2, %{turn_done: false})
  end

  defp handle_event(%{event: "stage", data: data}, state) do
    case data do
      %{"stage" => "turn", "state" => "done"} = d ->
        IO.puts(:stderr, "▸ turn done (exit_code=#{d["data"] |> get_in_json(["exit_code"])})")
        {:halt, state}

      %{"stage" => stage, "state" => st} ->
        IO.puts(:stderr, "▸ #{stage}: #{st}")
        {:cont, state}

      _ ->
        {:cont, state}
    end
  end

  defp handle_event(%{event: "output", data: data}, state) do
    text = format_output(data)
    if text != "", do: IO.write(text)
    {:cont, state}
  end

  defp handle_event(_, state), do: {:cont, state}

  defp get_in_json(s, path) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} -> get_in(m, path)
      _ -> nil
    end
  end

  defp get_in_json(_, _), do: nil

  defp format_output(%{"data" => raw, "stream" => "stderr"}) do
    "\e[31m" <> raw <> "\e[0m"
  end

  defp format_output(%{"data" => raw}) when is_binary(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.map_join("", &format_stream_json_line/1)
  end

  defp format_output(_), do: ""

  defp format_stream_json_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} ->
        Enum.map_join(content, "", fn
          %{"type" => "text", "text" => t} ->
            t

          %{"type" => "tool_use", "name" => n, "input" => i} ->
            "\n\e[36m[#{n}]\e[0m " <> Jason.encode!(i) <> "\n"

          _ ->
            ""
        end)

      {:ok, %{"type" => "user", "message" => %{"content" => [%{"content" => c} | _]}}}
      when is_binary(c) ->
        "\n\e[2m→ " <> truncate(c, 200) <> "\e[0m\n"

      {:ok, %{"type" => "result", "result" => r}} when is_binary(r) ->
        "\n\e[32m✓ " <> r <> "\e[0m\n"

      _ ->
        ""
    end
  end

  defp truncate(s, n) when byte_size(s) > n, do: binary_part(s, 0, n) <> "…"
  defp truncate(s, _), do: s

  # ── list / show / stream / prompt / terminate ────────────────────────────

  defp list(args) do
    json? = "--json" in args
    {:ok, %{"data" => convs}} = Api.get("/conversations")

    if json? do
      IO.puts(Jason.encode!(convs, pretty: true))
    else
      print_table(
        ["status", "id", "agent_id", "runtime", "started"],
        Enum.map(convs, fn c ->
          [c["status"], short(c["id"]), short(c["agent_id"]), c["runtime"], c["inserted_at"]]
        end)
      )
    end
  end

  defp show(id) do
    {:ok, %{"data" => conv}} = Api.get("/conversations/#{id}")
    {:ok, %{"data" => turns}} = Api.get("/conversations/#{id}/turns")

    IO.puts("conversation #{conv["id"]}")
    IO.puts("  status:    #{conv["status"]}")
    IO.puts("  agent:     #{conv["agent_id"]}")
    IO.puts("  sandbox:   #{conv["sandbox_id"]}")
    IO.puts("  sprite:    #{sprite_label(conv["sandbox"])}")
    IO.puts("  runtime:   #{conv["runtime"]}")
    IO.puts("  inserted:  #{conv["inserted_at"]}")
    IO.puts("\nturns (#{length(turns)}):")

    for t <- turns do
      IO.puts(
        "  ##{t["turn_number"]} #{t["status"]} exit=#{t["exit_code"]}  #{truncate(t["prompt"] || "", 80)}"
      )
    end
  end

  defp sprite_label(nil), do: "—"
  defp sprite_label(%{"sprite_name" => n, "status" => s}), do: "#{n} (#{s})"
  defp sprite_label(_), do: "—"

  defp stream(id) do
    Api.stream("/conversations/#{id}/stream", &handle_event/2, %{turn_done: false})
  end

  defp prompt(id, args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [prompt: :string, image: :keep],
        aliases: [p: :prompt, i: :image]
      )

    prompt_text = opts[:prompt] || FountainCli.die("missing -p <prompt>")

    image_paths = opts |> Keyword.get_values(:image)

    images =
      Enum.map(image_paths, fn path ->
        data = File.read!(path) |> Base.encode64()
        media_type = guess_media_type(path)
        %{data: data, media_type: media_type}
      end)

    body = %{prompt: prompt_text, images: images}

    case Api.post("/conversations/#{id}/prompts", body) do
      {:ok, _} -> follow_until_idle(id)
      {:error, e} -> FountainCli.die("#{inspect(e)}")
    end
  end

  defp guess_media_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/png"
    end
  end

  defp terminate(id) do
    case Api.post("/conversations/#{id}/terminate", %{}) do
      {:ok, _} -> IO.puts("terminated #{id}")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  defp interrupt(id) do
    case Api.post("/conversations/#{id}/interrupt", %{}) do
      {:ok, _} -> IO.puts("interrupted #{id}")
      {:error, {409, _}} -> FountainCli.die("no turn running")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  defp delete(id) do
    case Api.delete("/conversations/#{id}") do
      {:ok, _} -> IO.puts("deleted #{id}")
      {:error, {404, _}} -> FountainCli.die("not found")
      {:error, e} -> FountainCli.die(inspect(e))
    end
  end

  # ── shared helpers ────────────────────────────────────────────────────────

  defp short(nil), do: ""
  defp short(s) when is_binary(s) and byte_size(s) >= 8, do: binary_part(s, 0, 8)
  defp short(s), do: s

  defp print_table(headers, rows) do
    widths = column_widths(headers, rows)

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

  defp column_widths(headers, rows) do
    Enum.with_index(headers, fn h, i ->
      [to_string(h) | Enum.map(rows, fn r -> to_string(Enum.at(r, i) || "") end)]
      |> Enum.map(&String.length/1)
      |> Enum.max()
    end)
  end
end
