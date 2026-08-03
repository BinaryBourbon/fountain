defmodule Fountain.ToolchainLockstepTest do
  use ExUnit.Case, async: true

  # Guards the Erlang/Elixir toolchain pins against drifting apart (#404).
  # The toolchain is pinned in three places — `.tool-versions` (local dev via
  # mise), the `Dockerfile` build-stage base image (production release), and
  # the `erlef/setup-beam` inputs in `.github/workflows/ci.yml` — and
  # SETUP.md's parity reference says a bump must update all of them. Before
  # this test the rule existed only as prose, and had already been violated:
  # production built on an Elixir/OTP pair the suite never ran against.
  #
  # Parsing is tolerant of surrounding format (image tag suffix, quoting,
  # `-otp-N` qualifiers); version equality is strict.

  @repo_root Path.expand("../../../..", __DIR__)

  test ".tool-versions, the Dockerfile base image, and CI setup-beam pin the same Elixir and OTP" do
    tool_versions = parse_tool_versions()
    dockerfile = parse_dockerfile()
    ci = parse_ci()

    mismatches =
      for {language, key} <- [{"Elixir", :elixir}, {"Erlang/OTP", :otp}],
          pins = [
            {".tool-versions", tool_versions[key]},
            {"Dockerfile", dockerfile[key]},
            {".github/workflows/ci.yml", ci[key]}
          ],
          pins |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1 do
        rows = Enum.map_join(pins, "\n", fn {where, version} -> "    #{where}: #{version}" end)
        "  #{language} pins disagree:\n#{rows}"
      end

    assert mismatches == [],
           """
           The toolchain pins have drifted apart:

           #{Enum.join(mismatches, "\n")}

           Dev/CI and the production release image must build on the same
           Elixir and OTP. Update all three pins together — see the
           "Production parity reference" section of SETUP.md.
           """
  end

  # ── extraction ────────────────────────────────────────────────────────────
  #
  # Each parser asserts its own success so a format change fails loudly with
  # a pointer at the file that changed, instead of the main assertion
  # comparing nils.

  defp parse_tool_versions do
    source = File.read!(Path.join(@repo_root, ".tool-versions"))

    # `erlang 28.3`
    otp = capture(~r/^erlang\s+(\d+(?:\.\d+)*)\s*$/m, source)

    # `elixir 1.19.2-otp-28` — the `-otp-N` qualifier names the OTP major the
    # precompiled Elixir targets; the toolchain version is the leading part.
    elixir = capture(~r/^elixir\s+(\d+(?:\.\d+)*)(?:-otp-\d+)?\s*$/m, source)

    assert otp && elixir,
           "could not extract erlang/elixir pins from .tool-versions — the file format changed"

    %{elixir: elixir, otp: otp}
  end

  defp parse_dockerfile do
    source = File.read!(Path.join(@repo_root, "Dockerfile"))

    # `FROM hexpm/elixir:<elixir>-erlang-<otp>-<os...>` — tolerate any OS
    # suffix (debian/ubuntu/alpine, snapshot date, -slim).
    case Regex.run(
           ~r/^FROM\s+hexpm\/elixir:(\d+(?:\.\d+)*)-erlang-(\d+(?:\.\d+)*)-/m,
           source
         ) do
      [_, elixir, otp] ->
        %{elixir: elixir, otp: otp}

      nil ->
        flunk(
          "could not extract the hexpm/elixir base image tag from the Dockerfile — " <>
            "the FROM line or tag format changed"
        )
    end
  end

  defp parse_ci do
    source = File.read!(Path.join(@repo_root, ".github/workflows/ci.yml"))

    # `elixir-version: "1.19.2"` / `otp-version: "28.3"` (quotes optional)
    elixir = capture(~r/^\s*elixir-version:\s*"?(\d+(?:\.\d+)*)"?\s*$/m, source)
    otp = capture(~r/^\s*otp-version:\s*"?(\d+(?:\.\d+)*)"?\s*$/m, source)

    assert elixir && otp,
           "could not extract elixir-version/otp-version from .github/workflows/ci.yml — " <>
             "the setup-beam inputs changed"

    %{elixir: elixir, otp: otp}
  end

  defp capture(regex, source) do
    case Regex.run(regex, source, capture: :all_but_first) do
      [value] -> value
      nil -> nil
    end
  end
end
