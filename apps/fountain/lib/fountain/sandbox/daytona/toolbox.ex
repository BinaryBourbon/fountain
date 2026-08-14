defmodule Fountain.Sandbox.Daytona.Toolbox do
  @moduledoc """
  Daytona toolbox client — the in-sandbox REST API, proxied per sandbox at
  its `toolboxProxyUrl` (same Bearer auth as the control plane).

  Long-running commands are daemon-side *sessions*: a named session hosts
  async commands whose output is journaled server-side, streamable (and
  replayable from the start — the property reattach depends on) via the
  command's log endpoint. Stdin is a per-command FIFO that is line-oriented:
  the daemon appends a trailing newline when missing, which suits the
  NDJSON JSON-RPC the ACP path writes; `suppressInputEcho` keeps written
  input out of the output journal.
  """

  def req(toolbox_url) do
    Req.new(
      [
        base_url: toolbox_url,
        auth: {:bearer, Fountain.Sandbox.Daytona.Api.api_key!()},
        receive_timeout: Application.get_env(:fountain, :daytona_timeout_ms, 30_000)
      ] ++ Application.get_env(:fountain, :daytona_req_options, [])
    )
  end

  @doc "One-shot blocking exec with cwd/env/timeout. Returns output + exit code."
  def execute(toolbox_url, command, opts) do
    body =
      %{command: command}
      |> maybe_put(:cwd, Keyword.get(opts, :dir))
      |> maybe_put(:env, exec_env(opts))
      |> maybe_put(:timeout, exec_timeout_s(opts))

    case Req.post(req(toolbox_url), url: "/process/execute", json: body) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body["result"] || body["output"] || "", body["exitCode"] || body["code"] || 0}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_session(toolbox_url, session_id) do
    case Req.post(req(toolbox_url), url: "/process/session", json: %{sessionId: session_id}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      # Already there — session creation is idempotent intent.
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_sessions(toolbox_url) do
    case Req.get(req(toolbox_url), url: "/process/session") do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, %{status: 200, body: %{"sessions" => sessions}}} -> {:ok, sessions}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Start a command in the session asynchronously; returns its command id."
  def exec_async(toolbox_url, session_id, command) do
    body = %{command: command, runAsync: true, suppressInputEcho: true}

    case Req.post(req(toolbox_url), url: "/process/session/#{session_id}/exec", json: body) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case body["cmdId"] || body["commandId"] || body["id"] do
          id when is_binary(id) -> {:ok, id}
          _ -> {:error, {:no_command_id, body}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The command record; `exitCode` is nil while it is still running."
  def get_command(toolbox_url, session_id, command_id) do
    case Req.get(req(toolbox_url), url: "/process/session/#{session_id}/command/#{command_id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404, body: _}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Write to the command's stdin FIFO (line-oriented; daemon adds a newline)."
  def send_input(toolbox_url, session_id, command_id, data) do
    body = %{data: IO.iodata_to_binary(data)}
    url = "/process/session/#{session_id}/command/#{command_id}/input"

    case Req.post(req(toolbox_url), url: url, json: body) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The command's full journal so far (no follow) — raw bytes with the same
  channel markers the websocket carries, or a JSON map on older daemons.
  """
  def get_logs(toolbox_url, session_id, command_id) do
    url = "/process/session/#{session_id}/command/#{command_id}/logs"

    case Req.get(req(toolbox_url), url: url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The websocket URL that streams a command's journaled log from the start."
  def logs_ws_url(toolbox_url, session_id, command_id) do
    toolbox_url
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
    |> Kernel.<>("/process/session/#{session_id}/command/#{command_id}/logs?follow=true")
  end

  def write_file(toolbox_url, path, data) do
    form = [file: {IO.iodata_to_binary(data), filename: Path.basename(path)}]

    case Req.post(req(toolbox_url),
           url: "/files/upload-v2",
           params: [path: path],
           form_multipart: form
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec_env(opts) do
    case Keyword.get(opts, :env, []) do
      [] -> nil
      env -> Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
    end
  end

  defp exec_timeout_s(opts) do
    case Keyword.get(opts, :timeout, :infinity) do
      :infinity -> nil
      ms when is_integer(ms) -> max(div(ms, 1000), 1)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
