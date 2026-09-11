# A deterministic ACP agent, as a real program (#1634).
#
# This is what the `acp` runtime is for: not a model, just something that
# reads the Agent Client Protocol on stdin and answers it on stdout. It runs
# as its own OS process under `elixir`, uses OTP's own `:json` and depends on
# nothing else, so `conversation_server_acp_fixture_test.exs` drives a whole
# turn against a program rather than against a mock of one.
#
# One turn: `initialize`, `session/new`, then a `session/prompt` answered with
# a tool call, its completion, a message and a stop reason. A prompt whose
# text contains "ask" requests permission first and does as it is told.

defmodule FixtureAcpAgent do
  def run do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        line |> String.trim() |> dispatch()
        run()

      _eof_or_error ->
        :ok
    end
  end

  defp dispatch(""), do: :ok

  defp dispatch(line) do
    case :json.decode(line) do
      %{"method" => method, "id" => id, "params" => params} -> request(method, id, params)
      %{"id" => id, "result" => result} -> answer(id, result)
      _other -> :ok
    end
  rescue
    _ -> :ok
  end

  defp request("initialize", id, _params) do
    reply(id, %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => false}})
  end

  defp request("session/new", id, _params) do
    reply(id, %{"sessionId" => "fixture-session"})
  end

  defp request("session/prompt", id, params) do
    Process.put(:prompt_id, id)

    if params |> inspect() |> String.contains?("ask") do
      # Wait for the client's verdict before doing anything.
      write(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "session/request_permission",
        "params" => %{
          "sessionId" => "fixture-session",
          "toolCall" => %{"title" => "converge", "kind" => "execute"},
          "options" => [
            %{"optionId" => "go", "kind" => "allow_once"},
            %{"optionId" => "stop", "kind" => "reject_once"}
          ]
        }
      })
    else
      converge()
      reply(id, %{"stopReason" => "end_turn"})
    end
  end

  defp request(_method, _id, _params), do: :ok

  # The only response this agent asks for is the permission verdict.
  defp answer(1, %{"outcome" => %{"optionId" => "go"}}) do
    converge()
    reply(Process.get(:prompt_id), %{"stopReason" => "end_turn"})
  end

  defp answer(1, _result) do
    reply(Process.get(:prompt_id), %{"stopReason" => "refusal"})
  end

  defp answer(_id, _result), do: :ok

  defp converge do
    update(%{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "converge",
      "title" => "lifecycle apply",
      "kind" => "execute",
      "status" => "pending"
    })

    update(%{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "converge",
      "status" => "completed"
    })

    update(%{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "converged 3 resources"}
    })
  end

  defp update(payload) do
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "fixture-session", "update" => payload}
    })
  end

  defp reply(nil, _result), do: :ok
  defp reply(id, result), do: write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp write(message), do: IO.puts(:json.encode(message))
end

FixtureAcpAgent.run()
