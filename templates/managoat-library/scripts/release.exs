# The facts about a release of this package, in one place, so the PR gate and
# the publish workflow cannot disagree about them. A port of Fountain's
# scripts/sdk-release.mjs to the hex shape.
#
#   elixir scripts/release.exs state          -> JSON on stdout
#   elixir scripts/release.exs guard <base>   -> the PR gate; exits 1 on a problem
#
# No dependencies: this runs before `mix deps.get` in both callers. The version
# is read from the `@version` attribute in mix.exs rather than by loading the
# project, so it needs no compiled deps either.
defmodule Release do
  @mix "mix.exs"
  @changelog "CHANGELOG.md"

  # Files whose contents reach a consumer. Changing one needs a release. The
  # changelog is not here on purpose: requiring a version bump to write the
  # changelog entry for that very version is a loop with no entrance. Neither
  # are the tests, CI, or the README (hexdocs rebuilds it on the next release;
  # it never needs one of its own).
  @shipped_dirs ["lib/", "priv/"]
  @shipped_files ["mix.exs"]

  def main(["state"]) do
    {name, version} = manifest(nil)

    %{
      "name" => name,
      "version" => version,
      "published" => published?(name, version),
      "tag" => "v#{version}"
    }
    |> JSON.encode!()
    |> IO.puts()
  end

  def main(["guard", base]) do
    changed = git(["diff", "--name-only", "#{base}...HEAD"]) |> String.split("\n", trim: true)
    {name, head_version} = manifest(nil)
    {_, base_version} = manifest(base)
    bumped = head_version != base_version

    needs_release =
      Enum.filter(changed, fn path ->
        cond do
          # mix.exs ships, but a dev-only dependency or a comment does not
          # reach a consumer; compare the projection that does.
          path == @mix -> consumer_facing(read(nil)) != consumer_facing(read(base))
          path in @shipped_files -> true
          true -> Enum.any?(@shipped_dirs, &String.starts_with?(path, &1))
        end
      end)

    IO.puts("package:  #{name}")
    IO.puts("base:     #{base_version}")
    IO.puts("head:     #{head_version}#{if bumped, do: "  (bumped)", else: "  (unchanged)"}")
    IO.puts("touched:  #{length(changed)} file(s)")
    if needs_release != [], do: IO.puts("shipped:  #{Enum.join(needs_release, ", ")}")

    cond do
      needs_release != [] and not bumped ->
        fail(
          "This PR changes what #{name} ships (#{Enum.join(needs_release, ", ")}) but leaves " <>
            "@version at #{head_version}. Nothing publishes without a bump, so the change " <>
            "would sit on main unreleased. Bump @version in mix.exs, add a " <>
            "\"## [<version>]\" heading to CHANGELOG.md, and commit. To change the " <>
            "published surface without releasing, add the \"no-release\" label."
        )

      not bumped ->
        IO.puts("\nNo release needed for this PR.")

      true ->
        # From here on the PR claims a release, so everything that would make
        # the publish fail on main is checked here instead, where it is cheap.
        problems =
          [
            published?(name, head_version) &&
              "#{name} #{head_version} is already on hex, and hex never allows a version " <>
                "to be republished. Bump to something new.",
            not (File.read!(@changelog) =~ "## [#{head_version}]") &&
              "#{@changelog} has no \"## [#{head_version}]\" heading. A release says what changed."
          ]
          |> Enum.filter(&is_binary/1)

        case problems do
          [] -> IO.puts("\nRelease looks well-formed. Merging this publishes #{head_version}.")
          _ -> Enum.each(problems, &fail/1)
        end
    end

    if Process.get(:failed), do: System.halt(1)
  end

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/release.exs state | guard <base-ref>")
    System.halt(2)
  end

  # {app name, version} from mix.exs at HEAD (nil) or at a git ref.
  defp manifest(ref) do
    source = read(ref)

    with [_, name] <- Regex.run(~r/^\s*app:\s*:(\w+)/m, source),
         [_, version] <- Regex.run(~r/^\s*@version\s+"([^"]+)"/m, source) do
      {name, version}
    else
      _ -> raise "could not read app: and @version from #{@mix}#{if ref, do: " at #{ref}"}"
    end
  end

  defp read(nil), do: File.read!(@mix)
  defp read(ref), do: git(["show", "#{ref}:#{@mix}"])

  # mix.exs without what never reaches a consumer: comments, blank lines, and
  # dependencies confined to :dev or :test (`only:` on one line, the shape the
  # formatter writes). Everything else in the file (deps, package metadata,
  # elixir requirement, the application spec) is the package.
  defp consumer_facing(source) do
    source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reject(&(&1 =~ ~r/only:\s*(:dev|:test|\[\s*:(dev|test)\s*,\s*:(dev|test)\s*\])/))
  end

  # Whether hex already has this exact version. 200 yes, 404 no (a package
  # that does not exist at all also answers 404); anything else is a fault.
  defp published?(name, version) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    url = ~c"https://hex.pm/api/packages/#{name}/releases/#{version}"

    headers = [
      {~c"accept", ~c"application/json"},
      {~c"user-agent", ~c"managoat-release-script (#{name})"}
    ]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, headers}, [ssl: ssl, timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, _}} -> true
      {:ok, {{_, 404, _}, _, _}} -> false
      {:ok, {{_, status, _}, _, _}} -> raise "hex.pm answered #{status} for #{name} #{version}"
      {:error, reason} -> raise "hex.pm request failed: #{inspect(reason)}"
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{out}"
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "::error::#{message}")
    Process.put(:failed, true)
  end
end

Release.main(System.argv())
