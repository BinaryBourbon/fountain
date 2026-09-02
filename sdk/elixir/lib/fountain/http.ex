defmodule Fountain.HTTP do
  @moduledoc "Bearer-authenticated JSON HTTP with an injectable transport."

  alias Fountain.{Config, Error}

  @user_agent "fountain-sdk-elixir/0.1.0"
  defstruct [:config, :transport, timeout: 30_000]

  @type t :: %__MODULE__{config: Config.t(), transport: module(), timeout: timeout()}

  def user_agent, do: @user_agent

  def new(%Config{} = config, opts \\ []) do
    %__MODULE__{
      config: config,
      transport: Keyword.get(opts, :transport, Fountain.HTTP.Inets),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  def base_url(%__MODULE__{config: config}), do: config.base_url

  def url(%__MODULE__{config: config}, path, query \\ []) do
    base =
      if String.starts_with?(path, ["http://", "https://"]) do
        unless same_origin?(path, config.base_url),
          do:
            raise(ArgumentError, "absolute request URLs must have the configured Fountain origin")

        path
      else
        config.base_url <> "/" <> String.trim_leading(path, "/")
      end

    values =
      query
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> {to_string(key), query_value(value)} end)

    if values == [],
      do: base,
      else:
        base <> if(String.contains?(base, "?"), do: "&", else: "?") <> URI.encode_query(values)
  end

  def headers(http, extra \\ [])

  def headers(%__MODULE__{config: %{api_key: ""}}, _extra),
    do:
      {:error,
       %Error{
         message:
           "No Fountain API key. Pass :api_key, set FOUNTAIN_API_KEY, or run `fountain auth login`.",
         kind: :auth
       }}

  def headers(%__MODULE__{config: config}, extra) do
    base = [
      {"authorization", "Bearer #{config.api_key}"},
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    base =
      if config.parent_conversation_id,
        do: [{"x-fountain-parent-conversation-id", config.parent_conversation_id} | base],
        else: base

    {:ok, merge_headers(base, extra)}
  end

  @doc "Sends an HTTP request and returns its decoded JSON (or text) body."
  def request(%__MODULE__{} = http, method, path, opts \\ []) do
    url = url(http, path, opts[:query] || [])
    method = method |> to_string() |> String.upcase()

    with {:ok, headers} <- headers(http, opts[:headers] || []),
         {:ok, encoded, headers} <- encode_body(opts[:body], headers),
         {:ok, status, response_headers, raw} <-
           http.transport.request(
             method,
             url,
             put_accept(headers, opts[:accept]),
             encoded,
             Keyword.get(opts, :timeout, http.timeout)
           ) do
      body = decode_body(raw)

      if status in 200..299,
        do: {:ok, body},
        else: {:error, Error.for_status(status, body, method, url, response_headers)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, connection_error(method, url, reason)}
    end
  rescue
    error -> {:error, connection_error(to_string(method), to_string(path), error)}
  end

  def request!(http, method, path, opts \\ []) do
    case request(http, method, path, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  def data(http, method, path, opts \\ []) do
    with {:ok, body} <- request(http, method, path, opts),
         do: {:ok, if(is_map(body), do: body["data"], else: nil)}
  end

  def data!(http, method, path, opts \\ []),
    do: request!(http, method, path, opts) |> then(&if(is_map(&1), do: &1["data"], else: nil))

  def list(http, path, opts \\ []) do
    with {:ok, value} <- data(http, "GET", path, opts),
         do: {:ok, if(is_list(value), do: value, else: [])}
  end

  def list!(http, path, opts \\ []) do
    case list(http, path, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc false
  def stream(%__MODULE__{} = http, method, path, opts, on_chunk) do
    url = url(http, path, opts[:query] || [])
    method = method |> to_string() |> String.upcase()

    with {:ok, headers} <- headers(http, opts[:headers] || []) do
      result =
        http.transport.stream(
          method,
          url,
          put_accept(headers, opts[:accept] || "text/event-stream"),
          Keyword.get(opts, :timeout, :infinity),
          on_chunk
        )

      case result do
        {:ok, status, response_headers, response_body} ->
          stream_status(status, response_headers, response_body, method, url)

        {:ok, status, response_headers} ->
          stream_status(status, response_headers, nil, method, url)

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, connection_error(method, url, reason)}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, connection_error(method, url, reason)}
    end
  end

  defp stream_status(status, _headers, _body, _method, _url) when status in 200..299,
    do: :ok

  defp stream_status(status, headers, body, method, url),
    do: {:error, Error.for_status(status, decode_body(body), method, url, headers)}

  def decode_body(raw) when raw in [nil, ""], do: nil

  def decode_body(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> value
      _ -> raw
    end
  end

  defp encode_body(nil, headers), do: {:ok, nil, headers}

  defp encode_body(body, headers) do
    case Jason.encode(body) do
      {:ok, value} ->
        {:ok, value, merge_headers(headers, [{"content-type", "application/json"}])}

      {:error, reason} ->
        {:error,
         %Error{
           message: "could not JSON encode request body: #{inspect(reason)}",
           kind: :validation
         }}
    end
  end

  defp query_value(true), do: "true"
  defp query_value(false), do: "false"
  defp query_value(value) when is_list(value), do: Enum.join(value, ",")
  defp query_value(value), do: to_string(value)

  defp same_origin?(left, right) do
    left = URI.parse(left)
    right = URI.parse(right)

    {left.scheme, left.host, left.port || default_port(left.scheme)} ==
      {right.scheme, right.host, right.port || default_port(right.scheme)}
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: nil

  defp put_accept(headers, nil), do: headers
  defp put_accept(headers, accept), do: merge_headers(headers, [{"accept", accept}])

  defp merge_headers(left, right) do
    (left ++ Enum.map(right, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end))
    |> Enum.reverse()
    |> Enum.uniq_by(fn {k, _} -> String.downcase(k) end)
    |> Enum.reverse()
  end

  defp connection_error(method, url, reason),
    do: %Error{
      message: "#{method} #{url} failed: #{Exception.format_banner(:error, reason)}",
      kind: :connection
    }
end

defmodule Fountain.HTTP.Inets do
  @moduledoc false

  def request(method, url, headers, body, timeout) do
    ensure_started()
    request = request_tuple(method, url, headers, body)
    options = http_options(url, timeout)

    case :httpc.request(method_atom(method), request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, normalize_headers(response_headers), response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream(method, url, headers, timeout, on_chunk) do
    ensure_started()
    request = {String.to_charlist(url), char_headers(headers)}

    options = http_options(url, timeout)

    case :httpc.request(method_atom(method), request, options,
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, id} -> receive_stream(id, on_chunk, 200, [])
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_stream(id, on_chunk, status, headers) do
    receive do
      {:http, {^id, :stream_start, response_headers}} ->
        receive_stream(id, on_chunk, status, normalize_headers(response_headers))

      {:http, {^id, :stream, chunk}} ->
        on_chunk.(IO.iodata_to_binary(chunk))
        receive_stream(id, on_chunk, status, headers)

      {:http, {^id, :stream_end, response_headers}} ->
        {:ok, status, normalize_headers(response_headers) ++ headers, nil}

      {:http, {^id, {{_version, response_status, _reason}, response_headers, body}}} ->
        {:ok, response_status, normalize_headers(response_headers), IO.iodata_to_binary(body)}

      {:http, {^id, {:error, reason}}} ->
        {:error, reason}

      {:fountain_cancel_stream, requester} ->
        :httpc.cancel_request(id)
        send(requester, {:fountain_stream_cancelled, self()})
        {:error, :cancelled}
    end
  end

  defp request_tuple(method, url, headers, nil) when method in ["POST", "PUT", "PATCH"],
    do: {String.to_charlist(url), char_headers(headers), ~c"application/json", ""}

  defp request_tuple(_method, url, headers, nil),
    do: {String.to_charlist(url), char_headers(headers)}

  defp request_tuple(_method, url, headers, body),
    do: {String.to_charlist(url), char_headers(headers), ~c"application/json", body}

  defp char_headers(headers),
    do:
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

  defp normalize_headers(headers),
    do: Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp finite_timeout(:infinity), do: 30_000
  defp finite_timeout(timeout), do: timeout

  defp http_options(url, timeout) do
    base =
      if timeout == :infinity,
        do: [timeout: :infinity, autoredirect: false, autoretry: 0],
        else: [
          timeout: timeout,
          connect_timeout: finite_timeout(timeout),
          autoredirect: false,
          autoretry: 0
        ]

    case URI.parse(url) do
      %URI{scheme: "https", host: host} ->
        ssl = [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

        Keyword.put(base, :ssl, ssl)

      _ ->
        base
    end
  end

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete
  defp method_atom("HEAD"), do: :head

  defp ensure_started do
    :inets.start()
    :ssl.start()
  end
end
