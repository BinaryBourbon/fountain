defmodule Fountain.Buzz.Mcp do
  @moduledoc """
  Server-side MCP tools that let a hosted Buzz agent post to its channel
  (ADR 0020 Phase 2, gate #737 — the reply path).

  buzz-acp never publishes the agent's reply, and Fountain deliberately keeps the
  agent's Nostr key out of the sandbox. So instead of the sandbox running the
  `buzz` CLI, Fountain exposes `buzz_*` tools over MCP: the sandboxed agent calls
  a tool, and Fountain — holding the key server-side — signs and publishes on its
  behalf by shelling out to the baked `buzz` CLI. Every post is a tool call
  Fountain can see and audit; the nsec never leaves the server.

  This module is the pure protocol/tool layer: it handles a JSON-RPC request map
  against a `ctx` and returns a response map. The transport (an HTTP endpoint)
  and the `ctx` construction (resolving a conversation to its Buzz identity and
  decrypting the key) live above it, so the tool logic is testable without a
  network or a real key.

  `ctx` fields:
    * `:env`     — `[{name, value}]` the `BUZZ_*` credentials for the `buzz` CLI
    * `:buzz_bin` — path to the baked `buzz` binary
    * `:exec`    — `(bin, args, env) -> {output, exit_status}` (default `System.cmd`),
                   injectable for tests
    * `:audit`   — optional `(tool_name, args) -> any` called after a successful
                   publish, for the audit trail
  """

  # The MCP protocol revision we implement (Streamable HTTP transport).
  @protocol_version "2025-06-18"
  @server_info %{name: "fountain-buzz", version: "1"}

  @doc "The tool catalogue advertised by `tools/list`."
  def tools do
    [
      %{
        name: "buzz_send_message",
        description:
          "Post a message to a Buzz channel as this agent. Use this to reply — " <>
            "the agent's own text is not published anywhere else. Returns the " <>
            "published event id.",
        inputSchema: %{
          type: "object",
          properties: %{
            channel: %{type: "string", description: "Channel UUID to post in"},
            content: %{type: "string", description: "Message text (markdown, @mentions)"},
            reply_to: %{
              type: "string",
              description: "Optional event id (64-hex) to reply to, creating a thread"
            }
          },
          required: ["channel", "content"]
        }
      },
      %{
        name: "buzz_react",
        description: "Add an emoji reaction to a Buzz event (message) as this agent.",
        inputSchema: %{
          type: "object",
          properties: %{
            event: %{type: "string", description: "Event id (64-hex) to react to"},
            emoji: %{type: "string", description: "Emoji, e.g. 👍"}
          },
          required: ["event", "emoji"]
        }
      }
    ]
  end

  @doc """
  Handle one JSON-RPC 2.0 request map against `ctx`.

  Returns a response map to send back, or `:noreply` for a notification (a
  request with no `id`), which per JSON-RPC gets no response.
  """
  def handle(%{"method" => method} = req, ctx) do
    id = Map.get(req, "id")

    cond do
      is_nil(id) and String.starts_with?(method, "notifications/") ->
        :noreply

      true ->
        dispatch(method, id, Map.get(req, "params", %{}), ctx)
    end
  end

  defp dispatch("initialize", id, _params, _ctx) do
    result(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: @server_info
    })
  end

  defp dispatch("ping", id, _params, _ctx), do: result(id, %{})

  defp dispatch("tools/list", id, _params, _ctx), do: result(id, %{tools: tools()})

  defp dispatch("tools/call", id, %{"name" => name} = params, ctx) do
    call_tool(id, name, Map.get(params, "arguments", %{}), ctx)
  end

  defp dispatch(_unknown, nil, _params, _ctx), do: :noreply

  defp dispatch(method, id, _params, _ctx) do
    error(id, -32_601, "method not found: #{method}")
  end

  # ── tools ──────────────────────────────────────────────────────────────────

  defp call_tool(id, "buzz_send_message", args, ctx) do
    with {:ok, channel} <- require_arg(args, "channel"),
         {:ok, content} <- require_arg(args, "content") do
      argv =
        ["messages", "send", "--channel", channel, "--content", content] ++
          optional(args, "reply_to", "--reply-to")

      run(id, "buzz_send_message", args, argv, ctx)
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, "buzz_react", args, ctx) do
    with {:ok, event} <- require_arg(args, "event"),
         {:ok, emoji} <- require_arg(args, "emoji") do
      run(id, "buzz_react", args, ["reactions", "add", "--event", event, "--emoji", emoji], ctx)
    else
      {:error, msg} -> tool_error(id, msg)
    end
  end

  defp call_tool(id, name, _args, _ctx), do: tool_error(id, "unknown tool: #{name}")

  # Shell out to the baked `buzz` with the BUZZ_* creds in the environment (never
  # in argv). No shell is involved — args are passed as a list, so message
  # content cannot inject a command.
  defp run(id, tool, args, argv, ctx) do
    exec = Map.get(ctx, :exec, &default_exec/3)

    case exec.(ctx.buzz_bin, argv, ctx.env) do
      {output, 0} ->
        maybe_audit(ctx, tool, args)
        result(id, %{content: [text(output)], isError: false})

      {output, status} ->
        result(id, %{content: [text("buzz exited #{status}: #{output}")], isError: true})
    end
  end

  defp default_exec(bin, argv, env) do
    System.cmd(bin, argv, env: env, stderr_to_stdout: true)
  end

  defp maybe_audit(%{audit: audit}, tool, args) when is_function(audit, 2), do: audit.(tool, args)
  defp maybe_audit(_ctx, _tool, _args), do: :ok

  # ── helpers ────────────────────────────────────────────────────────────────

  defp require_arg(args, key) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing required argument: #{key}"}
    end
  end

  defp optional(args, key, flag) do
    case Map.get(args, key) do
      v when is_binary(v) and v != "" -> [flag, v]
      _ -> []
    end
  end

  defp text(str), do: %{type: "text", text: to_string(str)}

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  # A tool-level failure is a successful JSON-RPC response carrying isError, per
  # MCP — the model sees it and can recover, rather than the call itself failing.
  defp tool_error(id, message),
    do: result(id, %{content: [text(message)], isError: true})
end
