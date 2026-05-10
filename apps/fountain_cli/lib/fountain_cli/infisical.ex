defmodule FountainCli.Infisical do
  @moduledoc """
  `FountainCli.SecretResolver` implementation for Infisical.

  Wraps the `infisical` CLI to resolve references at apply time. Auth
  (login session, `INFISICAL_TOKEN` env, etc.) is handled by the CLI
  itself — aod doesn't see or store any Infisical credentials.

  Reference docs: https://infisical.com/docs/cli/overview

  ## URI shape

  Infisical needs more parameters than 1Password or Bitwarden Secrets
  Manager — it's project + environment + path + secret name. The URI
  encodes them positionally, with the last segment always being the
  name and anything between the env and the name forming the path:

      infisical://<project-id>/<env>/<name>
      infisical://<project-id>/<env>/<path>/<name>
      infisical://<project-id>/<env>/<a>/<b>/<name>          # path = /a/b

  An **empty** project segment falls through to whatever the
  `infisical` CLI already picks up — `.infisical.json` in the working
  directory or `INFISICAL_PROJECT_ID` from the env:

      infisical:///<env>/<name>
      infisical:///<env>/<path>/<name>

  Path defaults to `/` (root) when omitted.
  """

  @behaviour FountainCli.SecretResolver

  @prefix "infisical://"

  @typedoc "Optional injection points for testing."
  @type opts :: [
          find_executable: (String.t() -> String.t() | nil),
          cmd: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer})
        ]

  @impl true
  def prefix, do: @prefix

  @doc "True if the value is an Infisical reference."
  @spec ref?(any()) :: boolean()
  def ref?(v) when is_binary(v), do: String.starts_with?(v, @prefix)
  def ref?(_), do: false

  @doc """
  Resolve a single `infisical://...` reference.

      iex> FountainCli.Infisical.read("infisical://abc/prod/DATABASE_URL")
      {:ok, "postgres://..."}

  Errors:
    * `{:error, :infisical_not_installed}` — `infisical` is not on PATH.
    * `{:error, {:invalid_ref, reason}}` — URI is missing required segments.
    * `{:error, {:infisical_failed, output}}` — CLI exited non-zero.
  """
  @impl true
  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(ref), do: read(ref, [])

  @spec read(String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def read(@prefix <> rest, opts) when is_binary(rest) do
    with {:ok, parts} <- parse(rest),
         {:ok, path} <- find_infisical(opts) do
      args = build_args(parts)
      cmd = Keyword.get(opts, :cmd, &System.cmd/3)

      case cmd.(path, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim_trailing(output, "\n")}
        {output, _code} -> {:error, {:infisical_failed, String.trim(output)}}
      end
    end
  end

  def read(_other, _opts), do: {:error, {:invalid_ref, "missing infisical:// prefix"}}

  defp parse(rest) do
    segments = String.split(rest, "/", trim: false)

    case segments do
      [_project, env, name] when env != "" and name != "" ->
        {:ok, %{project: blank_to_nil(Enum.at(segments, 0)), env: env, path: "/", name: name}}

      [_project, env | path_and_name] when env != "" and length(path_and_name) >= 2 ->
        {name, path_segments} = List.pop_at(path_and_name, -1)

        cond do
          name == "" ->
            {:error, {:invalid_ref, "missing secret name (last segment)"}}

          Enum.any?(path_segments, &(&1 == "")) ->
            {:error, {:invalid_ref, "empty path segment"}}

          true ->
            {:ok,
             %{
               project: blank_to_nil(Enum.at(segments, 0)),
               env: env,
               path: "/" <> Enum.join(path_segments, "/"),
               name: name
             }}
        end

      _ ->
        {:error,
         {:invalid_ref,
          "expected infisical://<project?>/<env>/<path?>/<name> with at least env and name"}}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  defp find_infisical(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find.("infisical") do
      nil -> {:error, :infisical_not_installed}
      path -> {:ok, path}
    end
  end

  defp build_args(%{project: project, env: env, path: path, name: name}) do
    base = ["secrets", "get", name, "--env=" <> env, "--path=" <> path, "--plain"]
    if project, do: base ++ ["--projectId=" <> project], else: base
  end

  @impl true
  @spec format_error(term()) :: String.t()
  def format_error(:infisical_not_installed) do
    "Infisical CLI (`infisical`) not on PATH — install from https://infisical.com/docs/cli/overview"
  end

  def format_error({:invalid_ref, reason}) do
    "invalid infisical:// reference: " <> reason
  end

  def format_error({:infisical_failed, output}) when is_binary(output) and output != "" do
    output
  end

  def format_error({:infisical_failed, _}) do
    "infisical exited non-zero with no output"
  end

  def format_error(other), do: inspect(other)
end
