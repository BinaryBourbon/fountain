defmodule Fountain.Config do
  @moduledoc "Resolves Fountain credentials and endpoints."

  @default_base_url "https://managoat.com"
  @default_app_url "https://fountain-conversations.demo.managoat.com"

  defstruct [:base_url, :api_key, :app_url, :parent_conversation_id]

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t(),
          app_url: String.t(),
          parent_conversation_id: String.t() | nil
        }

  def default_base_url, do: @default_base_url
  def default_app_url, do: @default_app_url

  @doc "Resolves explicit options, environment variables, then the CLI credentials file."
  def resolve(opts \\ []) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    profile = present(opts[:profile]) || present(env.("FOUNTAIN_PROFILE")) || "default"
    credentials = read_credentials(profile, opts, env)

    base_url =
      present(opts[:base_url]) || present(env.("FOUNTAIN_BASE_URL")) ||
        present(credentials["base_url"]) || @default_base_url

    api_key =
      present(opts[:api_key]) || present(env.("FOUNTAIN_API_KEY")) ||
        present(env.("FOUNTAIN_TOKEN")) || present(credentials["api_key"]) || ""

    app_url =
      if Keyword.has_key?(opts, :app_url),
        do: String.trim(opts[:app_url] || ""),
        else: present(env.("FOUNTAIN_APP_URL")) || @default_app_url

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      api_key: api_key,
      app_url: String.trim_trailing(app_url, "/"),
      parent_conversation_id: present(env.("FOUNTAIN_CONVERSATION_ID"))
    }
  end

  @doc "Parses the INI-like file written by `fountain auth login`."
  def parse_credentials(raw, profile) do
    {_, values} =
      raw
      |> String.split(~r/\R/)
      |> Enum.reduce({nil, %{}}, fn raw_line, {section, values} ->
        line = String.trim(raw_line)

        cond do
          line == "" or String.starts_with?(line, ["#", ";"]) ->
            {section, values}

          Regex.match?(~r/^\[.*\]$/, line) ->
            {line |> String.trim_leading("[") |> String.trim_trailing("]") |> String.trim(),
             values}

          section != profile or not String.contains?(line, "=") ->
            {section, values}

          true ->
            [key, value] = String.split(line, "=", parts: 2)
            {section, Map.put(values, String.trim(key), unquote_value(value))}
        end
      end)

    values
  end

  def conversation_url(id, %__MODULE__{app_url: "", base_url: base}),
    do: "#{base}/api/conversations/#{id}"

  def conversation_url(id, %__MODULE__{app_url: app}), do: "#{app}/#/c/#{id}"

  defp read_credentials(profile, opts, env) do
    path =
      present(opts[:credentials_file]) || present(env.("FOUNTAIN_CREDENTIALS_FILE")) ||
        Path.join(System.user_home!(), ".fountain/credentials")

    case File.read(Path.expand(path)) do
      {:ok, raw} -> parse_credentials(raw, profile)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp unquote_value(value) do
    value = String.trim(value)

    if String.length(value) >= 2 and
         ((String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
            (String.starts_with?(value, "'") and String.ends_with?(value, "'"))) do
      value |> String.slice(1, String.length(value) - 2) |> String.trim()
    else
      value
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_), do: nil
end
