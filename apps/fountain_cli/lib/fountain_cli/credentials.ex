defmodule FountainCli.Credentials do
  @moduledoc """
  Reads and writes `~/.fountain/credentials` as an AWS-CLI-style
  multi-profile TOML file.

  File format::

      [default]
      api_key = "ftn_..."
      base_url = "https://fountain.dev"

      [staging]
      api_key = "ftn_..."
      base_url = "https://staging.fountain.dev"

  Profile selection precedence:
    1. `--profile <name>` parsed from opts
    2. `FOUNTAIN_PROFILE` env var
    3. `"default"`
  """

  @doc """
  Resolve the active profile name from opts, the `FOUNTAIN_PROFILE`
  environment variable, or fall back to `"default"`.
  """
  @spec profile_name(keyword()) :: String.t()
  def profile_name(opts) when is_list(opts) do
    cond do
      is_binary(opts[:profile]) and opts[:profile] != "" ->
        opts[:profile]

      (env = System.get_env("FOUNTAIN_PROFILE")) != nil ->
        env

      true ->
        "default"
    end
  end

  @doc """
  Read the named profile from the credentials file.
  Returns `%{}` when the file or profile is missing.
  """
  @spec read_profile(String.t()) :: map()
  def read_profile(profile) when is_binary(profile) do
    path = credentials_path()

    case File.read(path) do
      {:ok, content} ->
        content |> parse_all() |> Map.get(profile, %{})

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        FountainCli.die("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc """
  Write (upsert) a profile section to the credentials file.
  Other profiles are preserved unchanged.
  """
  @spec write_profile(String.t(), map()) :: :ok
  def write_profile(profile, attrs) when is_binary(profile) and is_map(attrs) do
    path = credentials_path()
    File.mkdir_p!(Path.dirname(path))

    all =
      case File.read(path) do
        {:ok, content} -> parse_all(content)
        {:error, :enoent} -> %{}
      end

    updated = Map.put(all, profile, attrs)
    File.write!(path, serialize(updated))
  end

  @doc """
  Delete a profile section from the credentials file.
  No-op if the file or profile does not exist.
  """
  @spec delete_profile(String.t()) :: :ok
  def delete_profile(profile) when is_binary(profile) do
    path = credentials_path()

    case File.read(path) do
      {:ok, content} ->
        all = parse_all(content)
        updated = Map.delete(all, profile)
        File.write!(path, serialize(updated))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        FountainCli.die("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc """
  Return the credentials file path.
  Defaults to `~/.fountain/credentials`; can be overridden in tests
  via `Application.put_env(:fountain_cli, :credentials_path_override, path)`.
  """
  @spec credentials_path() :: Path.t()
  def credentials_path do
    Application.get_env(:fountain_cli, :credentials_path_override) ||
      Path.join([System.user_home!(), ".fountain", "credentials"])
  end

  # ── TOML parsing ───────────────────────────────────────────────────

  @doc false
  def parse_all(content) when is_binary(content) do
    section_re = ~r/^\[([^\]]+)\]$/

    content
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, section} ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          {acc, section}

        String.match?(line, section_re) ->
          [_, name] = Regex.run(section_re, line)
          {acc, name}

        section != nil and String.contains?(line, "=") ->
          [key | rest] = String.split(line, "=", parts: 2)
          key = String.trim(key)
          value = rest |> hd() |> String.trim() |> strip_quotes()
          section_map = Map.get(acc, section, %{})
          {Map.put(acc, section, Map.put(section_map, key, value)), section}

        true ->
          {acc, section}
      end
    end)
    |> elem(0)
  end

  defp strip_quotes(<<?", rest::binary>>) when byte_size(rest) >= 1 do
    case String.ends_with?(rest, "\"") do
      true -> binary_part(rest, 0, byte_size(rest) - 1)
      false -> rest
    end
  end

  defp strip_quotes(s), do: s

  # ── TOML serialization ─────────────────────────────────────────────

  defp serialize(profiles) when is_map(profiles) do
    profiles
    |> Enum.sort_by(fn {name, _} -> if name == "default", do: "", else: name end)
    |> Enum.map_join("\n\n", fn {name, attrs} ->
      kv =
        attrs
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map_join("\n", fn {k, v} -> ~s(#{k} = "#{v}") end)

      "[#{name}]\n#{kv}"
    end)
    |> case do
      "" -> ""
      body -> body <> "\n"
    end
  end
end
