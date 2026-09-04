defmodule FountainBuzz.Assets do
  @moduledoc """
  Where this extension's native executables live, and whether they may be used
  (ADR 0043, #1509).

  Two binaries come from `block/buzz` rather than from this repository:
  `buzz-acp`, the harness, and `buzz`, the CLI the MCP tools shell out to for
  signed publishes. Both are downloaded and checksum-verified into the
  **bundled** image at `/usr/local/lib/fountain-buzz`; a core image carries
  neither, and every function here answers `nil` or `false` there rather than
  raising.

  ## The default path is the extension's, not the host's

  It used to be set from `config/runtime.exs` under `:fountain`. That made a
  core-only release's configuration name a path only the bundled image has,
  which is backwards: the extension is what knows where its own binaries are
  installed. Configuration still wins when it is set — a self-hoster who
  installs `buzz-acp` elsewhere sets `BUZZ_ACP_PATH` — and the default is only
  consulted when nothing did.

  ## Version compatibility

  `compatible?/0` refuses a binary whose version does not match the pin in
  `apps/fountain_buzz/buzz-acp.version`. A partial upgrade — a new extension
  beside an old binary, or the reverse — is a configuration that should stop
  before a harness starts rather than crash-loop one per identity, which is
  the failure #1509 asks for. The pin is read at compile time, so the check
  costs one string comparison.
  """

  require Logger

  @install_dir "/usr/local/lib/fountain-buzz"

  # Compile-time, from the file the publish workflow and the image build both
  # read. `@external_resource` so a repin recompiles this module rather than
  # leaving a stale expectation baked into the release.
  @version_file Path.join(__DIR__, "../../buzz-acp.version") |> Path.expand()
  @external_resource @version_file
  @pinned_version @version_file |> File.read!() |> String.trim()

  @doc "Where the bundled image installs the extension's binaries."
  @spec install_dir() :: String.t()
  def install_dir, do: @install_dir

  @doc """
  The pinned `buzz-acp` release, as `apps/fountain_buzz/buzz-acp.version` spells
  it. This is a Fountain release name (`buzz-acp-v<version>`), which may carry a
  fork suffix; see `.github/workflows/buzz-acp-publish.yml`.
  """
  @spec pinned_version() :: String.t()
  def pinned_version, do: @pinned_version

  @doc """
  The `buzz-acp` executable, or `nil` where this distribution has none.

  Configuration wins; the bundled image's install path is the fallback, and
  only when something is actually there.
  """
  @spec acp_path() :: String.t() | nil
  def acp_path do
    Application.get_env(:fountain_buzz, :buzz_acp_path) || default_path("buzz-acp")
  end

  @doc "The `buzz` CLI, or `nil` where this distribution has none."
  @spec cli_path() :: String.t() | nil
  def cli_path do
    Application.get_env(:fountain_buzz, :buzz_cli_bin) || default_path("buzz")
  end

  defp default_path(name) do
    path = Path.join(@install_dir, name)
    if File.exists?(path), do: path
  end

  @doc """
  Whether the installed `buzz-acp` is the one this extension was built against.

  `true` when the binary reports the pinned version, `false` when it reports a
  different one or cannot be asked. A `nil` path is `false` too — there is
  nothing to be compatible with — so a caller that wants "is Buzz runnable
  here" can ask this one question.

  Deliberately not a hard failure at boot. An operator who has pinned an
  override, or is mid-upgrade, gets an inert extension and a log line naming
  both versions, rather than a release that will not start.
  """
  @spec compatible?() :: boolean()
  def compatible? do
    case {acp_path(), installed_version()} do
      {nil, _installed} ->
        false

      {_path, @pinned_version} ->
        true

      {path, installed} ->
        Logger.warning(
          "buzz-acp at #{path} reports #{inspect(installed)} but fountain_buzz is built " <>
            "against #{inspect(@pinned_version)}; not starting harnesses. Repin " <>
            "apps/fountain_buzz/buzz-acp.version or rebuild the bundled image."
        )

        false
    end
  end

  @doc """
  The version the installed `buzz-acp` reports, or `nil`.

  `--version` output is `buzz-acp <semver>` upstream, and the pin may carry a
  Fountain fork suffix (`0.5.14-fountain.4`) that the binary itself does not
  know about — so the comparison is a prefix match on the upstream half, not
  equality with the whole release name.
  """
  @spec installed_version() :: String.t() | nil
  def installed_version do
    with path when is_binary(path) <- acp_path(),
         {output, 0} <- System.cmd(path, ["--version"], stderr_to_stdout: true) do
      normalise(output)
    else
      _anything -> nil
    end
  rescue
    # An unreadable or non-executable file is "cannot be asked", not a crash.
    _error -> nil
  end

  # `buzz-acp 0.5.14` against a pin of `0.5.14-fountain.4`: the fork suffix is
  # ours and the binary has never heard of it, so the pin's upstream half is
  # what a version report can possibly match.
  defp normalise(output) do
    reported =
      output
      |> String.trim()
      |> String.split()
      |> List.last()

    if is_binary(reported) and String.starts_with?(@pinned_version, reported),
      do: @pinned_version,
      else: reported
  end
end
