defmodule Fountain.Broker.Injector do
  @moduledoc """
  The header rewrite the proxy applies to one request (ADR 0019 §1, §4).

  A service binds a host to an auth shape and the credential keys it reads.
  When a request matches a service, the request's own auth header is dropped
  whatever it carried (the placeholder, usually) and the real one is written
  in its place. `proxy-authorization`, which carried the session token from
  the sandbox, never reaches the origin. When no service matches, the
  session's `unmatched_host_policy` decides: `passthrough` sends the request
  untouched, `deny` refuses it.

  Service shapes, as `Fountain.Broker` builds them and the session stores
  them (string keys after the round trip through the database):

      %{"host" => "api.github.com", "auth" => %{"type" => "bearer", "token" => "KEY"}}
      %{"auth" => %{"type" => "basic", "username" => "KEY", "password" => "KEY"}}
      %{"auth" => %{"type" => "api-key", "header" => "x-api-key", "key" => "KEY", "prefix" => "Token "}}
      %{"auth" => %{"type" => "custom", "headers" => %{"X-Key" => "{{ KEY }}"}}}

  The `auth` values name credential keys; the injector reads the values. A
  custom template resolves every `{{ KEY }}` it names.

  A service `host` is what `Fountain.SecretBindings.Binding` accepts:
  `host[:port][/path]`, where the host may be a `*.example.com` wildcard and
  the path a prefix, with `*` matching the rest. A port pins the request's
  port; without one any port matches.
  """

  @hop_by_hop ~w(proxy-authorization proxy-connection)
  @template_re ~r/\{\{\s*([A-Z][A-Z0-9_]*)\s*\}\}/

  @type header :: {String.t(), String.t()}

  @doc """
  Rewrite `headers` for a request to `host`:`port` at `path`. Returns
  `{:ok, headers, service_name}` with the name of the service applied
  (`nil` for passthrough), or `{:error, :denied}`.
  """
  @spec inject([header()], String.t(), :inet.port_number(), String.t(), map()) ::
          {:ok, [header()], String.t() | nil} | {:error, :denied}
  def inject(headers, host, port, path, %{services: services, credentials: credentials} = binding) do
    headers = Enum.reject(headers, fn {k, _} -> String.downcase(k) in @hop_by_hop end)

    case Enum.find(services, &matches?(&1["host"], host, port, path)) do
      nil ->
        if Map.get(binding, :unmatched_host_policy, "passthrough") == "deny",
          do: {:error, :denied},
          else: {:ok, headers, nil}

      %{"name" => name, "auth" => auth} ->
        {:ok, put_auth(headers, auth, credentials), name}
    end
  end

  @doc "Does a service `pattern` (`host[:port][/path]`) match this request?"
  @spec matches?(String.t(), String.t(), :inet.port_number(), String.t()) :: boolean()
  def matches?(pattern, host, port, path) when is_binary(pattern) do
    {host_part, path_part} =
      case String.split(pattern, "/", parts: 2) do
        [h] -> {h, nil}
        [h, p] -> {h, "/" <> p}
      end

    {host_pattern, port_pattern} =
      case String.split(host_part, ":", parts: 2) do
        [h] -> {h, nil}
        [h, p] -> {h, p}
      end

    host_matches?(String.downcase(host_pattern), String.downcase(host)) and
      port_matches?(port_pattern, port) and path_matches?(path_part, path)
  end

  defp host_matches?("*." <> suffix, host), do: String.ends_with?(host, "." <> suffix)
  defp host_matches?(pattern, host), do: pattern == host

  defp port_matches?(nil, _port), do: true
  defp port_matches?(pattern, port), do: pattern == Integer.to_string(port)

  defp path_matches?(nil, _path), do: true

  defp path_matches?(pattern, path) do
    path = path |> String.split("?", parts: 2) |> hd()

    if String.ends_with?(pattern, "*"),
      do: String.starts_with?(path, String.trim_trailing(pattern, "*")),
      else: path == pattern or String.starts_with?(path, pattern <> "/")
  end

  defp put_auth(headers, %{"type" => "bearer", "token" => key}, creds) do
    replace(headers, "authorization", "Bearer " <> Map.fetch!(creds, key))
  end

  defp put_auth(headers, %{"type" => "basic", "username" => u, "password" => p}, creds) do
    pair = Map.fetch!(creds, u) <> ":" <> Map.fetch!(creds, p)
    replace(headers, "authorization", "Basic " <> Base.encode64(pair))
  end

  defp put_auth(headers, %{"type" => "api-key", "key" => key} = auth, creds) do
    header = Map.get(auth, "header") || "Authorization"
    replace(headers, header, Map.get(auth, "prefix", "") <> Map.fetch!(creds, key))
  end

  defp put_auth(headers, %{"type" => "custom", "headers" => templates}, creds) do
    Enum.reduce(templates, headers, fn {name, template}, acc ->
      replace(acc, name, render(template, creds))
    end)
  end

  defp put_auth(headers, %{"type" => "passthrough"}, _creds), do: headers

  # Every `{{ KEY }}` the session holds a value for; one it does not is left
  # as written, which the origin then refuses, rather than sent empty.
  defp render(template, creds) do
    Regex.replace(@template_re, template, fn whole, key ->
      Map.get(creds, key, whole)
    end)
  end

  defp replace(headers, name, value) do
    down = String.downcase(name)
    [{name, value} | Enum.reject(headers, fn {k, _} -> String.downcase(k) == down end)]
  end
end
