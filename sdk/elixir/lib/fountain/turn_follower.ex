defmodule Fountain.TurnFollower do
  @moduledoc "Folds a raw conversation event feed into one turn's answer."
  defstruct [
    :turn_number,
    :turn_id,
    :state,
    :exit_code,
    :reason,
    started: false,
    chunks: [],
    tools: [],
    break_before_text: false
  ]

  def new(turn_number, turn_id \\ nil),
    do: %__MODULE__{turn_number: turn_number, turn_id: turn_id}

  def text(value), do: value.chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
  def tools_used(value), do: Enum.reverse(value.tools)
  def finished?(value), do: not is_nil(value.state)

  @doc "Applies one raw, string-keyed API event, returning `{follower, run_events}`."
  def apply(follower, %{"kind" => "stage"} = event), do: apply_stage(follower, event)
  def apply(follower, %{"kind" => "output"} = event), do: apply_output(follower, event)
  def apply(follower, _event), do: {follower, []}

  defp apply_stage(follower, %{"stage" => "turn"} = event) do
    meta = object(event["data"])

    if matches?(follower, meta) do
      case event["state"] do
        "started" ->
          follower = %{
            follower
            | started: true,
              turn_id: string(meta["turn_id"]) || follower.turn_id
          }

          {follower,
           [%{type: :turn_start, turn_number: follower.turn_number, turn_id: follower.turn_id}]}

        state when state in ~w(done failed interrupted) ->
          follower = %{
            follower
            | state: String.to_atom(state),
              turn_id: follower.turn_id || string(meta["turn_id"]),
              exit_code:
                if(is_integer(meta["exit_code"]), do: meta["exit_code"], else: follower.exit_code),
              reason: string(meta["reason"]) || string(meta["stop_reason"]) || follower.reason
          }

          {follower,
           [
             %{
               type: :turn_end,
               state: follower.state,
               exit_code: follower.exit_code,
               reason: follower.reason
             }
           ]}

        _ ->
          {follower, []}
      end
    else
      {follower, []}
    end
  end

  defp apply_stage(follower, _event), do: {follower, []}

  defp apply_output(follower, event) do
    event_turn_id = string(event["turn_id"])

    if (not is_nil(follower.turn_id) and not is_nil(event_turn_id) and
          event_turn_id != follower.turn_id) or
         (not follower.started and is_nil(follower.turn_id)) do
      {follower, []}
    else
      Enum.reduce(event["blocks"] || [], {follower, []}, fn block, {state, output} ->
        if is_map(block) do
          {state, derived} = apply_block(state, block, event["stream"] == "acp")
          {state, output ++ [%{type: :block, block: block, event: event}] ++ derived}
        else
          {state, output}
        end
      end)
    end
  end

  defp apply_block(follower, %{"kind" => "text"} = block, acp) do
    body = if is_binary(block["body"]), do: block["body"], else: ""
    if body == "", do: {follower, []}, else: append_text(follower, body, acp)
  end

  defp apply_block(follower, %{"kind" => "thinking"} = block, _),
    do:
      {follower,
       if(is_binary(block["body"]) and block["body"] != "",
         do: [%{type: :thinking, text: block["body"]}],
         else: []
       )}

  defp apply_block(follower, %{"kind" => kind}, _) when kind in ["raw", "init"],
    do: {follower, []}

  defp apply_block(follower, %{"kind" => "permission_request"} = block, _) do
    follower = %{follower | break_before_text: true}

    case permission_request(block) do
      nil -> {follower, []}
      request -> {follower, [%{type: :permission, request: request, block: block}]}
    end
  end

  defp apply_block(follower, %{"kind" => "tool_use"} = block, _) do
    follower = %{follower | break_before_text: true}
    name = string(block["name"])

    follower =
      if name && name not in follower.tools,
        do: %{follower | tools: [name | follower.tools]},
        else: follower

    {follower, if(name, do: [%{type: :tool, name: name, block: block}], else: [])}
  end

  defp apply_block(%{chunks: []} = follower, %{"kind" => "result", "body" => body}, _)
       when is_binary(body) and body != "",
       do: {%{follower | chunks: [body], break_before_text: true}, [%{type: :text, text: body}]}

  defp apply_block(follower, %{"kind" => "error", "body" => body}, _)
       when is_binary(body) and body != "" do
    text = "\n[error] #{body}\n"

    {%{follower | chunks: [text | follower.chunks], break_before_text: true},
     [%{type: :text, text: text}]}
  end

  defp apply_block(follower, _block, _), do: {%{follower | break_before_text: true}, []}

  defp append_text(follower, body, acp) do
    prefix =
      cond do
        follower.chunks == [] -> ""
        acp and not follower.break_before_text -> ""
        String.ends_with?(hd(follower.chunks), "\n") -> ""
        true -> "\n\n"
      end

    chunks = if prefix == "", do: [body | follower.chunks], else: [body, prefix | follower.chunks]

    {%{follower | chunks: chunks, break_before_text: false},
     [%{type: :text, text: prefix <> body}]}
  end

  defp permission_request(block) do
    request_id = string(block["request_id"])

    options =
      (block["options"] || [])
      |> Enum.flat_map(fn option ->
        if is_map(option) do
          id = string(option["optionId"]) || string(option["option_id"])
          if id, do: [Map.put(option, :option_id, id)], else: []
        else
          []
        end
      end)

    if request_id && options != [],
      do: %{
        request_id: request_id,
        summary: string(block["summary"]) || string(block["body"]),
        tool_name: string(block["name"]),
        tool_id: string(block["tool_id"]),
        options: options
      }
  end

  defp matches?(%{turn_id: id} = follower, meta) when is_binary(id),
    do: string(meta["turn_id"]) == id or meta["turn_number"] == follower.turn_number

  defp matches?(follower, meta), do: meta["turn_number"] == follower.turn_number
  defp object(value) when is_map(value), do: value

  defp object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp object(_), do: %{}
  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil
end
