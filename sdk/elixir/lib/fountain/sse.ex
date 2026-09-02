defmodule Fountain.SSE do
  @moduledoc "SSE parsing and reconnecting Fountain event streams."

  alias Fountain.HTTP

  @doc "Parses an enumerable of binary chunks into SSE message maps."
  def parse_sse(chunks) do
    {messages, state} =
      Enum.reduce(chunks, {[], %{buffer: ""}}, fn chunk, {all, state} ->
        {next, state} = feed(state, IO.iodata_to_binary(chunk))
        {all ++ next, state}
      end)

    messages ++
      case parse_message(state.buffer) do
        nil -> []
        message -> [message]
      end
  end

  @doc "Returns a reconnecting enumerable for a conversation's event feed."
  def stream_events(http, conversation_id, opts \\ []) do
    stream_path(
      http,
      "/api/conversations/#{conversation_id}/stream",
      Keyword.put_new(opts, :blocks, true)
    )
  end

  @doc "Returns a reconnecting enumerable for any Fountain SSE endpoint."
  def stream_path(http, path, opts \\ []) do
    Stream.resource(
      fn -> start_worker(http, path, opts) end,
      &next_event/1,
      &stop_worker/1
    )
  end

  @doc false
  def feed(%{buffer: buffer} = state, chunk) do
    split_messages(%{state | buffer: buffer <> chunk}, [])
  end

  defp split_messages(%{buffer: buffer} = state, acc) do
    case boundary(buffer) do
      nil ->
        {Enum.reverse(acc), state}

      {index, length} ->
        <<message::binary-size(index), _separator::binary-size(length), rest::binary>> = buffer

        acc =
          case parse_message(message) do
            nil -> acc
            value -> [value | acc]
          end

        split_messages(%{state | buffer: rest}, acc)
    end
  end

  defp boundary(buffer) do
    values =
      [{:binary.match(buffer, "\r\n\r\n"), 4}, {:binary.match(buffer, "\n\n"), 2}]
      |> Enum.flat_map(fn
        {{index, _}, length} -> [{index, length}]
        {:nomatch, _} -> []
      end)

    Enum.min_by(values, &elem(&1, 0), fn -> nil end)
  end

  defp parse_message(chunk) do
    fields =
      chunk
      |> String.split("\n")
      |> Enum.reduce(%{"id" => nil, "event" => "message", "data" => []}, fn raw, out ->
        line = String.trim_trailing(raw, "\r")

        if line == "" or String.starts_with?(line, ":") do
          out
        else
          {field, value} =
            case String.split(line, ":", parts: 2) do
              [field] -> {field, ""}
              [field, " " <> value] -> {field, value}
              [field, value] -> {field, value}
            end

          case field do
            "id" -> %{out | "id" => value}
            "event" -> %{out | "event" => value}
            "data" -> Map.update!(out, "data", &(&1 ++ [value]))
            _ -> out
          end
        end
      end)

    if fields["data"] == [] and is_nil(fields["id"]),
      do: nil,
      else: %{fields | "data" => Enum.join(fields["data"], "\n")}
  end

  defp start_worker(http, path, opts) do
    owner = self()
    ref = make_ref()

    pid = spawn(fn -> supervise_worker(owner, ref, http, path, opts) end)

    %{pid: pid, ref: ref, pending_ack: nil}
  end

  defp next_event(state) do
    if state.pending_ack,
      do: send(state.pending_ack, {:fountain_sse_demand, state.ref})

    state = %{state | pending_ack: nil}

    receive do
      {:fountain_sse, ref, {:event, event, producer}} when ref == state.ref ->
        {[event], %{state | pending_ack: producer}}

      {:fountain_sse, ref, :done} when ref == state.ref ->
        {:halt, state}

      {:fountain_sse, ref, {:error, error}} when ref == state.ref ->
        raise error
    end
  end

  defp stop_worker(%{pid: pid, ref: ref}) when is_pid(pid) do
    stop_ref = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:stop, self(), stop_ref})

    receive do
      {:stopped, ^stop_ref} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      500 -> Process.exit(pid, :kill)
    end

    Process.demonitor(monitor, [:flush])
    drain_stream(ref)
  end

  defp drain_stream(ref) do
    receive do
      {:fountain_sse, ^ref, _message} -> drain_stream(ref)
    after
      0 -> :ok
    end
  end

  defp supervise_worker(owner, ref, http, path, opts) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)

    child =
      spawn_link(fn ->
        reconnect(owner, ref, http, path, opts, Keyword.get(opts, :after, 0), 0)
      end)

    timeout = if opts[:deadline], do: max(opts[:deadline] - now(), 0), else: :infinity

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        shutdown_child(child)

      {:stop, stopper, stop_ref} ->
        shutdown_child(child)
        send(stopper, {:stopped, stop_ref})

      {:EXIT, ^child, :normal} ->
        :ok

      {:EXIT, ^child, reason} ->
        send(
          owner,
          {:fountain_sse, ref,
           {:error,
            %Fountain.Error{
              message: "SSE worker stopped: #{Exception.format_exit(reason)}",
              kind: :connection
            }}}
        )
    after
      timeout ->
        send(
          owner,
          {:fountain_sse, ref,
           {:error, %Fountain.Error{message: "SSE stream deadline reached", kind: :connection}}}
        )

        shutdown_child(child)
    end
  end

  defp shutdown_child(child) do
    send(child, {:fountain_cancel_stream, self()})

    receive do
      {:fountain_stream_cancelled, ^child} -> :ok
      {:EXIT, ^child, _reason} -> :ok
    after
      250 -> Process.exit(child, :kill)
    end
  end

  defp reconnect(owner, ref, http, path, opts, last_id, attempt) do
    if deadline_expired?(opts) do
      send(
        owner,
        {:fountain_sse, ref,
         {:error, %Fountain.Error{message: "SSE stream deadline reached", kind: :connection}}}
      )

      exit(:normal)
    end

    max_retries = Keyword.get(opts, :max_retries, 5)
    wait? = Keyword.get(opts, :wait, true)
    parser = :ets.new(:sse_parser, [:set, :private])
    :ets.insert(parser, {:state, %{buffer: ""}, last_id})

    on_chunk = fn chunk ->
      [{:state, parse_state, current_id}] = :ets.lookup(parser, :state)
      {messages, next_state} = feed(parse_state, chunk)

      next_id =
        Enum.reduce(messages, current_id, fn message, cursor ->
          case decode_event(message) do
            nil ->
              cursor

            event ->
              send_event(owner, ref, event)
              if is_integer(event["id"]) and event["id"] > cursor, do: event["id"], else: cursor
          end
        end)

      :ets.insert(parser, {:state, next_state, next_id})
      :ets.insert(parser, {:progress, true})
    end

    headers = if last_id > 0, do: [{"last-event-id", Integer.to_string(last_id)}], else: []

    query = [
      blocks: if(opts[:blocks], do: "true"),
      streams: streams(opts[:streams]),
      wait: if(wait?, do: nil, else: "false")
    ]

    result =
      HTTP.stream(
        http,
        "GET",
        path,
        [
          query: query,
          headers: headers,
          accept: "text/event-stream",
          timeout: stream_timeout(opts)
        ],
        on_chunk
      )

    [{:state, tail_state, current_last_id}] = :ets.lookup(parser, :state)

    new_last_id =
      case parse_message(tail_state.buffer) do
        nil ->
          current_last_id

        message ->
          case decode_event(message) do
            nil ->
              current_last_id

            event ->
              send_event(owner, ref, event)

              if is_integer(event["id"]),
                do: max(current_last_id, event["id"]),
                else: current_last_id
          end
      end

    progressed? = :ets.member(parser, :progress)
    :ets.delete(parser)

    # A connection that delivered data proves the endpoint is reachable, so the
    # retry budget starts over. Carrying the count forward kills a stream that
    # has run for hours on its `max_retries`th lifetime disconnect, however much
    # successful streaming sat in between. The TypeScript client resets the same
    # counter the moment it has a 2xx response (sdk/typescript/src/sse.ts).
    attempt = if progressed?, do: 0, else: attempt

    cond do
      result == :ok and not wait? ->
        send(owner, {:fountain_sse, ref, :done})

      result == :ok and max_retries > 0 ->
        retry(owner, ref, http, path, opts, new_last_id, 1)

      result == :ok ->
        send(owner, {:fountain_sse, ref, :done})

      match?({:error, %Fountain.Error{status: status}} when status in 400..499, result) ->
        send(owner, {:fountain_sse, ref, result})

      attempt < max_retries ->
        retry(owner, ref, http, path, opts, new_last_id, attempt + 1)

      true ->
        send(owner, {:fountain_sse, ref, result})
    end
  end

  defp retry(owner, ref, http, path, opts, last_id, attempt) do
    delay = Keyword.get(opts, :retry_delay, 500) * max(attempt, 1)
    delay = if opts[:deadline], do: min(delay, max(opts[:deadline] - now(), 0)), else: delay
    Process.sleep(delay)
    reconnect(owner, ref, http, path, opts, last_id, attempt)
  end

  defp decode_event(%{"data" => ""}), do: nil

  defp decode_event(message) do
    with {:ok, payload} when is_map(payload) <- Jason.decode(message["data"]) do
      id =
        case Integer.parse(message["id"] || "") do
          {value, ""} when value > 0 -> value
          _ -> payload["id"]
        end

      payload = if id, do: Map.put(payload, "id", id), else: payload

      if is_nil(payload["kind"]) and message["event"] in ["output", "stage"],
        do: Map.put(payload, "kind", message["event"]),
        else: payload
    else
      _ -> nil
    end
  end

  defp streams(value) when is_list(value), do: Enum.join(value, ",")
  defp streams(value), do: value

  defp send_event(owner, ref, event) do
    send(owner, {:fountain_sse, ref, {:event, event, self()}})

    receive do
      {:fountain_sse_demand, ^ref} ->
        :ok

      {:fountain_cancel_stream, requester} ->
        send(requester, {:fountain_stream_cancelled, self()})
        exit(:normal)
    end
  end

  defp deadline_expired?(opts), do: opts[:deadline] && opts[:deadline] <= now()

  defp stream_timeout(opts),
    do:
      if(opts[:deadline],
        do: max(opts[:deadline] - now(), 0),
        else: opts[:idle_timeout] || :infinity
      )

  defp now, do: System.monotonic_time(:millisecond)
end
