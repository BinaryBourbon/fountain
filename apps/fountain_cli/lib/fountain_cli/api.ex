defmodule FountainCli.Api do
  @moduledoc """
  Thin HTTP wrapper over `:httpc`. Returns parsed JSON bodies for ok
  responses and explicit errors otherwise.

  Credential resolution delegates to `FountainCli.Config`, which reads
  `FOUNTAIN_API_KEY` / `FOUNTAIN_BASE_URL` env vars first, then falls
  through to `~/.fountain/credentials`.
  """

  def base_url(opts \\ []), do: FountainCli.Config.base_url(opts)

  defp api_path(path), do: "/api" <> path

  def token(opts \\ []), do: FountainCli.Config.api_key(opts)

  def get(path, opts \\ []), do: request(:get, api_path(path), nil, opts)
  def post(path, body, opts \\ []), do: request(:post, api_path(path), body, opts)
  def put(path, body, opts \\ []), do: request(:put, api_path(path), body, opts)
  def delete(path, opts \\ []), do: request(:delete, api_path(path), nil, opts)

  defp request(method, path, body, opts) do
    url = (base_url(opts) <> path) |> String.to_charlist()
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(token(opts))}]

    request_tuple =
      case body do
        nil -> {url, headers}
        b -> {url, headers, ~c"application/json", Jason.encode!(b)}
      end

    case :httpc.request(method, request_tuple, [], body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status in 200..299 ->
        decode(resp_body)

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:error, {status, decode(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(""), do: {:ok, nil}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, m} -> {:ok, m}
      {:error, _} -> {:ok, body}
    end
  end

  @doc """
  Open an SSE stream for the given path. Calls `on_event` with each parsed
  `%{id, event, data}` map and the running state. Blocks until the server
  closes or `on_event` returns `{:halt, state}`.

  Implementation: shells out to `curl -N` via a Port.
  """
  def stream(path, on_event, init_state, opts \\ []) do
    url = base_url() <> api_path(path)
    last_id = Keyword.get(opts, :last_event_id)

    args =
      ["-sS", "-N", "--no-buffer", url, "-H", "Authorization: Bearer #{token()}"] ++
        if(last_id, do: ["-H", "Last-Event-ID: #{last_id}"], else: [])

    curl = System.find_executable("curl") || FountainCli.die("curl not found on PATH")

    port =
      Port.open({:spawn_executable, curl}, [
        :binary,
        :exit_status,
        args: args
      ])

    sse_loop(port, on_event, init_state, "")
  end

  defp sse_loop(port, on_event, state, buffer) do
    receive do
      {^port, {:data, chunk}} ->
        {events, leftover} = FountainCli.Sse.feed(buffer <> chunk)

        result =
          Enum.reduce_while(events, {:cont, state}, fn ev, {_, acc} ->
            case on_event.(ev, acc) do
              {:cont, s} -> {:cont, {:cont, s}}
              {:halt, s} -> {:halt, {:halt, s}}
            end
          end)

        case result do
          {:cont, s} ->
            sse_loop(port, on_event, s, leftover)

          {:halt, s} ->
            Port.close(port)
            s
        end

      {^port, {:exit_status, _code}} ->
        state
    after
      300_000 ->
        Port.close(port)
        FountainCli.die("stream timeout")
    end
  end
end
