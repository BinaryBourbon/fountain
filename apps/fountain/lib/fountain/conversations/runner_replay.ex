defmodule Fountain.Conversations.RunnerReplay do
  @moduledoc """
  Locate an active ACP turn in a runner's complete process journal.

  The ACP peer allocates consecutive request IDs and sends a new prompt only
  after the previous request has answered. The response immediately before the
  persisted prompt ID separates earlier turns and handshake output from the
  active turn. Hosted providers may replay a partial tail and do not use this
  boundary; the process runner guarantees replay from byte zero.
  """

  @max_line_bytes 4 * 1024 * 1024

  def new(prompt_id) when is_integer(prompt_id) and prompt_id > 0,
    do: %{previous_id: prompt_id - 1, buffer: ""}

  def feed(nil, data), do: {:ok, nil, data}

  def feed(state, data) when is_binary(data) do
    scan(%{state | buffer: state.buffer <> data})
  end

  defp scan(state) do
    case :binary.match(state.buffer, "\n") do
      :nomatch ->
        if byte_size(state.buffer) <= @max_line_bytes,
          do: {:ok, state, ""},
          else: {:error, :runner_replay_line_too_large}

      {at, 1} when at <= @max_line_bytes ->
        <<line::binary-size(at), "\n", rest::binary>> = state.buffer

        if boundary?(line, state.previous_id),
          do: {:ok, nil, rest},
          else: scan(%{state | buffer: rest})

      _ ->
        {:error, :runner_replay_line_too_large}
    end
  end

  defp boundary?(line, previous_id) do
    case Jason.decode(line) do
      {:ok, %{"jsonrpc" => "2.0", "id" => ^previous_id} = response} ->
        not Map.has_key?(response, "method") and
          (Map.has_key?(response, "result") or Map.has_key?(response, "error"))

      _ ->
        false
    end
  end
end
