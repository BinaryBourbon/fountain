defmodule Fountain.TestServer do
  def start(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    pid = spawn(fn -> accept(listener, handler) end)
    %{listener: listener, pid: pid, url: "http://127.0.0.1:#{port}"}
  end

  def stop(server) do
    :gen_tcp.close(server.listener)
    Process.exit(server.pid, :kill)
  end

  defp accept(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, handler) end)
        accept(listener, handler)

      _ ->
        :ok
    end
  end

  defp serve(socket, handler) do
    with {:ok, request} <- read_request(socket) do
      case handler.(request) do
        {status, headers, body} ->
          body = IO.iodata_to_binary(body)
          send_response(socket, status, [{"content-length", byte_size(body)} | headers], body)

        {:stream, status, headers, chunks} ->
          send_head(socket, status, [{"transfer-encoding", "chunked"} | headers])

          Enum.each(chunks, fn {delay, chunk} ->
            Process.sleep(delay)
            chunk = IO.iodata_to_binary(chunk)

            :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
          end)

          :gen_tcp.send(socket, "0\r\n\r\n")
      end
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket), do: read_headers(socket, "")

  defp read_headers(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        <<head::binary-size(index), _::binary-size(4), rest::binary>> = buffer
        [request_line | header_lines] = String.split(head, "\r\n")
        [method, target, _version] = String.split(request_line, " ", parts: 3)

        headers =
          Map.new(header_lines, fn line ->
            [key, value] = String.split(line, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        length = headers |> Map.get("content-length", "0") |> String.to_integer()
        {:ok, body} = read_body(socket, rest, length)
        uri = URI.parse(target)

        {:ok,
         %{
           method: method,
           target: target,
           path: uri.path,
           query: URI.decode_query(uri.query || ""),
           headers: headers,
           body: body
         }}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, data} -> read_headers(socket, buffer <> data)
          error -> error
        end
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length,
    do: {:ok, binary_part(body, 0, length)}

  defp read_body(socket, body, length) do
    with {:ok, data} <- :gen_tcp.recv(socket, length - byte_size(body), 2_000),
         do: read_body(socket, body <> data, length)
  end

  defp send_response(socket, status, headers, body) do
    send_head(socket, status, headers)
    :gen_tcp.send(socket, body)
  end

  defp send_head(socket, status, headers) do
    reason =
      %{
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        302 => "Found",
        401 => "Unauthorized",
        422 => "Unprocessable Entity",
        503 => "Service Unavailable"
      }[status] || "Error"

    values = [{"connection", "close"} | headers]

    head = [
      "HTTP/1.1 #{status} #{reason}\r\n",
      Enum.map(values, fn {key, value} -> "#{key}: #{value}\r\n" end),
      "\r\n"
    ]

    :gen_tcp.send(socket, head)
  end
end
