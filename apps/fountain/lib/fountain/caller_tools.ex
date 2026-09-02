defmodule Fountain.CallerTools do
  @moduledoc """
  The tool bridge (#1202): tools a *client* defines on a chat-completions or
  AG-UI request, offered to the agent beside its own, and routed back to the
  client as `tool_calls` when the agent uses one.

  ADR 0035 decision 4 refused to emit the *sandbox's* tool use as a tool
  call, because that asks the client to run something that already ran. A
  caller-defined tool is the opposite case: it exists only on the client, the
  sandbox cannot run it, and the client is the only party that can return a
  result. So the amended rule is: **a tool call is emitted if and only if the
  tool came from the request's `tools`.** Fountain's own tools keep running
  in the sandbox with no round trip.

  ## The mechanism

  1. **Register.** A request with `tools` stores the normalised list on the
     conversation row (`conversations.caller_tools`; last write wins, an
     unchanged list is a no-op). The sandbox's MCP config gains one more
     Fountain-served server, `POST /api/mcp/caller/:conversation_id`, whose
     `tools/list` is exactly those tools. Nothing tells the agent they are
     remote.
  2. **Park.** When the agent calls one, `Mcp.call_tool/3` parks the call on
     the `ConversationServer` (`park_caller_tool/4`), which publishes a
     `caller_tool` / `started` stage event carrying the id, the name and the
     arguments. The MCP handler then waits on the result for up to
     `@wait_seconds` — under the tunnel's idle limit, the same cap
     `Fountain.Team.Mcp.wait_for_teammate` lives with — and answers
     `pending` with the call id if nothing arrived, so the agent calls
     `wait_for_caller_result` until it does. A client that answers within
     seconds (every framework loop) gets the result in the first round trip.
  3. **Emit.** The controllers map that stage event to the dialect's tool
     call (`tool_calls` + `finish_reason: "tool_calls"`; AG-UI
     `TOOL_CALL_START/ARGS/END`), and close the completion while the turn
     stays open.
  4. **Resume.** The next request on the thread whose newest messages are
     `role: "tool"` resolves the parked calls with their contents
     (`answer_caller_tools/2`); the MCP handler returns them to the agent and
     the controller streams the rest of the turn. A `user` message while
     calls are pending is refused (409 `tool_calls_pending`).
  5. **Clock.** A parked call has a deadline (`Managoat.ACP.Permissions`'s ask
     timeout). On expiry the agent gets an error result ("the caller did not
     answer"), the turn continues, and the stream records it. A turn that
     ends with calls still parked resolves them the same way.

  The registry lives on the row so the sandbox can list it whether or not a
  server is running; the parked calls live only in `ConversationServer`
  state, because the HTTP request they answer dies with the BEAM anyway.
  """

  alias Fountain.Conversations.Conversation

  @mcp_name "fountain-caller"
  @wait_tool "wait_for_caller_result"
  @name_re ~r/^[A-Za-z0-9_-]{1,64}$/
  @max_tools 128

  def mcp_name, do: @mcp_name
  def wait_tool, do: @wait_tool

  @doc """
  The MCP server entry for a conversation that has caller tools, in the
  shape `session/new` takes; `[]` otherwise. Injected at every turn kick
  beside the team and Buzz servers.
  """
  @spec conversation_mcp_servers(Conversation.t() | map(), String.t() | nil) :: [map()]
  def conversation_mcp_servers(%{caller_tools: [_ | _], id: conv_id}, token)
      when is_binary(token) and token != "" do
    [
      %{
        name: @mcp_name,
        type: "http",
        url: Fountain.PublicUrl.base() <> "/api/mcp/caller/" <> conv_id,
        headers: [%{name: "Authorization", value: "Bearer " <> token}]
      }
    ]
  end

  def conversation_mcp_servers(_conv, _token), do: []

  ## ─── Normalising a request's tools ───────────────────────────────────────

  @doc """
  The OpenAI `tools` + `tool_choice` of a chat-completions request, as the
  stored list. `tool_choice: "none"` unregisters for this request;
  `"required"` or a named tool is refused, because Fountain cannot force an
  agent's next action.
  """
  @spec from_openai(term(), term()) :: {:ok, [map()]} | {:error, String.t()}
  def from_openai(tools, tool_choice) do
    case tool_choice do
      nil ->
        normalize(tools, &openai_tool/1)

      "auto" ->
        normalize(tools, &openai_tool/1)

      "none" ->
        {:ok, []}

      "required" ->
        {:error,
         "tool_choice `required` is not supported: Fountain cannot force an agent's next action"}

      %{} ->
        {:error,
         "a named tool_choice is not supported: Fountain cannot force an agent's next action"}

      _ ->
        {:error, "tool_choice must be `auto`, `none`, or absent"}
    end
  end

  @doc "The AG-UI `tools` of a run input (`name`, `description`, `parameters`), as the stored list."
  @spec from_agui(term()) :: {:ok, [map()]} | {:error, String.t()}
  def from_agui(tools), do: normalize(tools, &agui_tool/1)

  defp normalize(nil, _), do: {:ok, []}
  defp normalize([], _), do: {:ok, []}

  defp normalize(tools, fun) when is_list(tools) and length(tools) <= @max_tools do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case fun.(tool) do
        {:ok, t} -> {:cont, {:ok, [t | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> check_unique(Enum.reverse(list))
      err -> err
    end
  end

  defp normalize(tools, _) when is_list(tools),
    do: {:error, "at most #{@max_tools} tools per request"}

  defp normalize(_, _), do: {:error, "tools must be an array"}

  defp openai_tool(%{"type" => "function", "function" => %{} = fun}), do: tool_entry(fun)
  defp openai_tool(%{"function" => %{} = fun}), do: tool_entry(fun)

  defp openai_tool(_),
    do: {:error, "each tool must be `{\"type\": \"function\", \"function\": {...}}`"}

  defp agui_tool(%{"name" => _} = tool), do: tool_entry(tool)
  defp agui_tool(_), do: {:error, "each tool must have a `name`"}

  defp tool_entry(%{"name" => name} = fun) when is_binary(name) do
    cond do
      not Regex.match?(@name_re, name) ->
        {:error,
         "tool name `#{String.slice(name, 0, 40)}` must match #{inspect(@name_re.source)}"}

      name == @wait_tool ->
        {:error, "tool name `#{@wait_tool}` is reserved"}

      true ->
        {:ok,
         %{
           "name" => name,
           "description" => string_or(fun["description"], ""),
           "parameters" => map_or(fun["parameters"], %{"type" => "object", "properties" => %{}})
         }}
    end
  end

  defp tool_entry(_), do: {:error, "each tool needs a string `name`"}

  defp string_or(v, _default) when is_binary(v), do: v
  defp string_or(_, default), do: default
  defp map_or(v, _default) when is_map(v), do: v
  defp map_or(_, default), do: default

  defp check_unique(list) do
    names = Enum.map(list, & &1["name"])

    if length(Enum.uniq(names)) == length(names),
      do: {:ok, list},
      else: {:error, "tool names must be unique"}
  end

  ## ─── Reading a request's tool answers ────────────────────────────────────

  @doc """
  The trailing `role: "tool"` messages of a request, as `%{call_id => content}`.
  `{:ok, %{}}` when the newest message is not a tool answer, so the request is
  a prompt. Reads both spellings of the id (`tool_call_id` in OpenAI's
  dialect, `toolCallId` in AG-UI's).
  """
  @spec tool_answers([map()]) :: %{String.t() => String.t()}
  def tool_answers(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(is_map(&1) and &1["role"] == "tool"))
    |> Enum.reduce(%{}, fn msg, acc ->
      case msg["tool_call_id"] || msg["toolCallId"] do
        id when is_binary(id) and id != "" -> Map.put(acc, id, answer_text(msg["content"]))
        _ -> acc
      end
    end)
  end

  def tool_answers(_), do: %{}

  defp answer_text(content) when is_binary(content), do: content

  defp answer_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> Jason.encode!(other)
    end)
  end

  defp answer_text(nil), do: ""
  defp answer_text(other), do: Jason.encode!(other)

  @doc "A parked call in OpenAI's `tool_calls` shape."
  @spec to_openai_call(map()) :: map()
  def to_openai_call(%{id: id, name: name, arguments: args}) do
    %{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(args || %{})}}
  end

  ## ─── The MCP server ──────────────────────────────────────────────────────

  defmodule Mcp do
    @moduledoc """
    The JSON-RPC layer of the caller-tool server, same shape as
    `Fountain.Team.Mcp`. `ctx` is `%{conversation: conv}`, the tenant-scoped
    row `FountainWeb.CallerMcpController` resolved; `tools/list` is the row's
    `caller_tools` plus `wait_for_caller_result`, and `tools/call` parks the
    call on the conversation's server and waits for the client's answer.
    """

    alias Fountain.CallerTools
    alias Fountain.Conversations.ConversationServer

    @protocol_version "2025-06-18"
    @server_info %{name: "fountain-caller", version: "1"}

    # The in-request wait, under the tunnel's ~100 s idle limit (the same
    # bound `Fountain.Team.Mcp` observes).
    @default_wait 60
    @max_wait 90

    @doc "The tool catalogue: the caller's tools, then the wait tool."
    def tools(%{caller_tools: tools}) when is_list(tools) do
      Enum.map(tools, fn t ->
        %{name: t["name"], description: t["description"], inputSchema: t["parameters"]}
      end) ++ [wait_tool()]
    end

    def tools(_conv), do: [wait_tool()]

    defp wait_tool do
      %{
        name: CallerTools.wait_tool(),
        description:
          "Wait for the result of a tool call that came back `pending`. The tool runs on " <>
            "the side of whoever is talking to you; the answer arrives when they send it. " <>
            "Blocks up to timeout_seconds (default #{@default_wait}, max #{@max_wait}); if it " <>
            "returns pending again, call it again. Do not end your turn to wait.",
        inputSchema: %{
          type: "object",
          properties: %{
            call_id: %{type: "string", description: "The call_id a pending result named"},
            timeout_seconds: %{type: "integer", description: "How long to block"}
          },
          required: ["call_id"]
        }
      }
    end

    @doc "Handle one JSON-RPC 2.0 request map against `ctx`; `:noreply` for notifications."
    def handle(%{"method" => method} = req, ctx) do
      id = Map.get(req, "id")

      if is_nil(id) and String.starts_with?(method, "notifications/"),
        do: :noreply,
        else: dispatch(method, id, Map.get(req, "params", %{}), ctx)
    end

    def handle(_req, _ctx), do: error(nil, -32_600, "invalid request")

    defp dispatch("initialize", id, _params, _ctx) do
      result(id, %{
        protocolVersion: @protocol_version,
        capabilities: %{tools: %{}},
        serverInfo: @server_info
      })
    end

    defp dispatch("ping", id, _params, _ctx), do: result(id, %{})

    defp dispatch("tools/list", id, _params, %{conversation: conv}),
      do: result(id, %{tools: tools(conv)})

    defp dispatch("tools/call", id, %{"name" => name} = params, ctx),
      do: call_tool(id, name, Map.get(params, "arguments") || %{}, ctx)

    defp dispatch("tools/call", id, _params, _ctx),
      do: error(id, -32_602, "tools/call needs a name")

    defp dispatch(method, id, _params, _ctx),
      do: error(id, -32_601, "method not found: #{method}")

    # `wait_for_caller_result`: re-attach to a call this handler (or an
    # earlier one that timed out) parked, and wait again.
    defp call_tool(id, wait, args, %{conversation: conv}) when wait == "wait_for_caller_result" do
      call_id = to_string(args["call_id"] || "")

      case ConversationServer.await_caller_tool(conv.id, call_id, self()) do
        {:ok, result} -> tool_result(id, answer(result))
        :pending -> tool_result(id, wait_for(call_id, wait_ms(args)))
        {:error, :unknown_call} -> tool_error(id, "no such call: #{call_id}")
        {:error, :not_running} -> tool_error(id, "the conversation is not running")
      end
    end

    defp call_tool(id, name, args, %{conversation: conv}) do
      known? = Enum.any?(conv.caller_tools || [], &(&1["name"] == name))

      cond do
        not known? ->
          tool_error(id, "unknown tool: #{name}")

        not is_map(args) ->
          tool_error(id, "arguments must be an object")

        true ->
          case ConversationServer.park_caller_tool(conv.id, name, args, self()) do
            {:ok, call_id} -> tool_result(id, wait_for(call_id, wait_ms(args)))
            {:error, :not_running} -> tool_error(id, "the conversation is not running")
            {:error, :no_turn} -> tool_error(id, "no turn is running")
          end
      end
    end

    # The server sends `{:caller_tool_result, id, result}` to the waiter it was
    # given. Nothing else lands in a request process's mailbox that matters.
    defp wait_for(call_id, wait_ms) do
      receive do
        {:caller_tool_result, ^call_id, result} -> answer(result)
      after
        wait_ms ->
          %{
            "pending" => true,
            "call_id" => call_id,
            "hint" =>
              "the caller has not answered yet; call #{CallerTools.wait_tool()} with this call_id"
          }
      end
    end

    defp answer({:ok, content}), do: content
    defp answer({:error, reason}), do: {:error, reason}

    # `timeout_seconds` is read off a caller tool's arguments too, but only if
    # the caller's own schema happens to declare it; otherwise the default.
    defp wait_ms(args) do
      args
      |> Map.get("timeout_seconds", @default_wait)
      |> case do
        n when is_integer(n) -> n
        _ -> @default_wait
      end
      |> max(1)
      |> min(@max_wait)
      |> Kernel.*(1_000)
    end

    defp tool_result(id, {:error, reason}), do: tool_error(id, reason)

    defp tool_result(id, content) when is_binary(content),
      do: result(id, %{content: [%{type: "text", text: content}], isError: false})

    defp tool_result(id, content),
      do: result(id, %{content: [%{type: "text", text: Jason.encode!(content)}], isError: false})

    defp tool_error(id, message),
      do: result(id, %{content: [%{type: "text", text: message}], isError: true})

    defp result(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

    defp error(id, code, message),
      do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
  end
end
