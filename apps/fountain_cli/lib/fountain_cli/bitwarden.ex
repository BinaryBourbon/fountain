defmodule FountainCli.Bitwarden do
  @moduledoc """
  `FountainCli.SecretResolver` implementation for Bitwarden Secrets Manager.

  Wraps the `bws` CLI to resolve `bws://<secret-uuid>` references at
  apply time. Authentication is via the `BWS_ACCESS_TOKEN` env var
  (consumed by `bws` directly) — aod doesn't see or store any
  Bitwarden credentials.

  Reference docs: https://bitwarden.com/help/secrets-manager-cli/

  Note: this is the **Secrets Manager** CLI (`bws`), not the personal
  vault CLI (`bw`). `bws` is the right fit for IaC / CI flows because
  it uses a single static access token and a UUID-based addressing
  scheme. If you need personal-vault `bw://` support, that's a
  separate resolver — open an issue.
  """

  @behaviour FountainCli.SecretResolver

  @prefix "bws://"

  @typedoc "Optional injection points for testing."
  @type opts :: [
          find_executable: (String.t() -> String.t() | nil),
          cmd: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer})
        ]

  @impl true
  def prefix, do: @prefix

  @doc "True if the value is a Bitwarden Secrets Manager reference."
  @spec ref?(any()) :: boolean()
  def ref?(v) when is_binary(v), do: String.starts_with?(v, @prefix)
  def ref?(_), do: false

  @doc """
  Resolve a single `bws://<uuid>` reference.

      iex> FountainCli.Bitwarden.read("bws://be8e0ad8-...")
      {:ok, "ghp_..."}

  Errors:
    * `{:error, :bws_not_installed}` — `bws` is not on PATH.
    * `{:error, :empty_ref}` — `bws://` with no UUID after it.
    * `{:error, {:bws_failed, output}}` — `bws` exited non-zero.
    * `{:error, {:bws_unexpected_output, reason}}` — couldn't parse
      the JSON or it didn't have a `value` field.
  """
  @impl true
  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(ref), do: read(ref, [])

  @spec read(String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def read(@prefix <> uuid, opts) when is_binary(uuid) do
    cond do
      uuid == "" ->
        {:error, :empty_ref}

      true ->
        find = Keyword.get(opts, :find_executable, &System.find_executable/1)
        cmd = Keyword.get(opts, :cmd, &System.cmd/3)

        case find.("bws") do
          nil ->
            {:error, :bws_not_installed}

          path ->
            case cmd.(path, ["secret", "get", uuid], stderr_to_stdout: true) do
              {output, 0} -> parse_secret(output)
              {output, _code} -> {:error, {:bws_failed, String.trim(output)}}
            end
        end
    end
  end

  def read(_other, _opts), do: {:error, :invalid_ref}

  defp parse_secret(output) do
    case Jason.decode(output) do
      {:ok, %{"value" => v}} when is_binary(v) ->
        {:ok, v}

      {:ok, _} ->
        {:error, {:bws_unexpected_output, "JSON had no string `value` field"}}

      {:error, _} ->
        {:error, {:bws_unexpected_output, "could not parse `bws` output as JSON"}}
    end
  end

  @impl true
  @spec format_error(term()) :: String.t()
  def format_error(:bws_not_installed) do
    "Bitwarden Secrets Manager CLI (`bws`) not on PATH — install from https://bitwarden.com/help/secrets-manager-cli/"
  end

  def format_error(:empty_ref) do
    "bws://<uuid> reference is missing the UUID"
  end

  def format_error(:invalid_ref) do
    "invalid bws:// reference"
  end

  def format_error({:bws_failed, output}) when is_binary(output) and output != "" do
    output
  end

  def format_error({:bws_failed, _}) do
    "bws exited non-zero with no output"
  end

  def format_error({:bws_unexpected_output, msg}) do
    "unexpected bws output: " <> msg
  end

  def format_error(other), do: inspect(other)
end
