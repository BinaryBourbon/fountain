defmodule Managoat.Broker.Injector do
  @moduledoc """
  The header rewrite the proxy applies to one request.

  A `Managoat.Broker.Rule` binds a host pattern to an auth shape and a
  credential. When a request matches a rule that sets a header, the
  request's own copy of that header is dropped whatever it carried (the
  placeholder, usually) and the real one is written in its place.
  `proxy-authorization`, which carried the session token from the sandbox,
  never reaches the origin. When no rule matches, the session's
  `unmatched_host_policy` decides: `:passthrough` sends the request
  untouched, `:deny` refuses it.

  Several rules may match. The first matched rule that sets a header is the
  one that does (a host's rules are in the order the host declared them);
  every matched `:substitute` rule applies to the header values.
  """

  alias Managoat.Broker.{Rule, Session}

  @hop_by_hop ~w(proxy-authorization proxy-connection)
  @template_re ~r/\{\{\s*([A-Z][A-Z0-9_]*)\s*\}\}/

  @type header :: {String.t(), String.t()}

  @doc """
  Rewrite `headers` for a request to `host`:`port` at `path`. Returns
  `{:ok, headers, rule_name}` with the name of the first matched rule
  (`nil` for passthrough), or `{:error, :denied}`.
  """
  @spec inject([header()], String.t(), :inet.port_number(), String.t(), Session.t()) ::
          {:ok, [header()], String.t() | nil} | {:error, :denied}
  def inject(headers, host, port, path, %Session{} = session) do
    headers = Enum.reject(headers, fn {k, _} -> String.downcase(k) in @hop_by_hop end)

    case Enum.filter(session.rules, &matches?(&1.pattern, host, port, path)) do
      [] ->
        if session.unmatched_host_policy == :deny,
          do: {:error, :denied},
          else: {:ok, headers, nil}

      [first | _] = matched ->
        headers =
          matched
          |> Enum.filter(&(&1.scheme == :substitute))
          |> Enum.reduce(headers, &substitute/2)

        headers =
          case Enum.find(matched, &(&1.scheme not in [:substitute, :passthrough])) do
            nil -> headers
            rule -> put_auth(headers, rule)
          end

        {:ok, headers, first.name}
    end
  end

  @doc "Does the host part of a rule `pattern` match this host and port, whatever the path?"
  @spec host_matches?(String.t(), String.t(), :inet.port_number()) :: boolean()
  def host_matches?(pattern, host, port) when is_binary(pattern) do
    host_only = pattern |> String.split("/", parts: 2) |> hd()
    matches?(host_only, host, port, "/")
  end

  @doc "Does a rule `pattern` (`host[:port][/path]`) match this request?"
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

    host_pattern_matches?(String.downcase(host_pattern), String.downcase(host)) and
      port_matches?(port_pattern, port) and path_matches?(path_part, path)
  end

  defp host_pattern_matches?("*." <> suffix, host), do: String.ends_with?(host, "." <> suffix)
  defp host_pattern_matches?(pattern, host), do: pattern == host

  defp port_matches?(nil, _port), do: true
  defp port_matches?(pattern, port), do: pattern == Integer.to_string(port)

  defp path_matches?(nil, _path), do: true

  defp path_matches?(pattern, path) do
    path = path |> String.split("?", parts: 2) |> hd()

    if String.ends_with?(pattern, "*"),
      do: String.starts_with?(path, String.trim_trailing(pattern, "*")),
      else: path == pattern or String.starts_with?(path, pattern <> "/")
  end

  defp put_auth(headers, %Rule{scheme: :bearer, credential: token}) when is_binary(token) do
    replace(headers, "authorization", "Bearer " <> token)
  end

  defp put_auth(headers, %Rule{scheme: :basic, credential: {user, pass}})
       when is_binary(user) and is_binary(pass) do
    replace(headers, "authorization", "Basic " <> Base.encode64(user <> ":" <> pass))
  end

  defp put_auth(headers, %Rule{scheme: :api_key, credential: value} = rule)
       when is_binary(value) do
    replace(headers, rule.header || "Authorization", (rule.prefix || "") <> value)
  end

  defp put_auth(headers, %Rule{scheme: :custom, template: templates, credential: creds})
       when is_map(templates) and is_map(creds) do
    Enum.reduce(templates, headers, fn {name, template}, acc ->
      replace(acc, name, render(template, creds))
    end)
  end

  # Every `{{ KEY }}` the rule holds a value for; one it does not is left
  # as written, which the origin then refuses, rather than sent empty.
  defp render(template, creds) do
    Regex.replace(@template_re, template, fn whole, key ->
      Map.get(creds, key, whole)
    end)
  end

  defp substitute(%Rule{placeholder: placeholder, credential: value}, headers)
       when is_binary(placeholder) and placeholder != "" and is_binary(value) do
    Enum.map(headers, fn {k, v} -> {k, String.replace(v, placeholder, value)} end)
  end

  defp substitute(_rule, headers), do: headers

  defp replace(headers, name, value) do
    down = String.downcase(name)
    [{name, value} | Enum.reject(headers, fn {k, _} -> String.downcase(k) == down end)]
  end
end
