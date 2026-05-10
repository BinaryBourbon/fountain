defmodule FountainCli.OnePassword do
  @moduledoc """
  `FountainCli.SecretResolver` implementation for 1Password.

  Wraps the `op` CLI to resolve `op://<vault>/<item>/<field>`
  references at apply time. Authentication (biometric unlock, session,
  account selection) is handled entirely by `op` — aod doesn't see or
  store any 1Password credentials.

  Reference docs: https://developer.1password.com/docs/cli/secret-references
  """

  @behaviour FountainCli.SecretResolver

  @prefix "op://"

  @typedoc "Optional injection points for testing."
  @type opts :: [
          find_executable: (String.t() -> String.t() | nil),
          cmd: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer})
        ]

  @impl true
  def prefix, do: @prefix

  @doc "True if the value is a 1Password secret reference."
  @spec ref?(any()) :: boolean()
  def ref?(v) when is_binary(v), do: String.starts_with?(v, @prefix)
  def ref?(_), do: false

  @doc """
  Resolve a single `op://...` reference.

      iex> FountainCli.OnePassword.read("op://Personal/GitHub/token")
      {:ok, "ghp_..."}

  Errors:
    * `{:error, :op_not_installed}` — `op` is not on PATH.
    * `{:error, {:op_failed, output}}` — `op` exited non-zero; `output`
      includes its combined stdout+stderr (e.g. "session expired").
  """
  @impl true
  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(ref), do: read(ref, [])

  @spec read(String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def read(ref, opts) when is_binary(ref) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)

    case find.("op") do
      nil ->
        {:error, :op_not_installed}

      path ->
        # `--no-newline` so we don't carry a trailing \n into the
        # secret value — most secrets explode in unhelpful ways
        # ("invalid token") if you accidentally include one.
        case cmd.(path, ["read", "--no-newline", ref], stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, _code} -> {:error, {:op_failed, String.trim(output)}}
        end
    end
  end

  @impl true
  @spec format_error(term()) :: String.t()
  def format_error(:op_not_installed) do
    "1Password CLI (`op`) not on PATH — install from https://developer.1password.com/docs/cli/get-started"
  end

  def format_error({:op_failed, output}) when is_binary(output) and output != "" do
    output
  end

  def format_error({:op_failed, _}) do
    "op exited non-zero with no output"
  end

  def format_error(other), do: inspect(other)
end
