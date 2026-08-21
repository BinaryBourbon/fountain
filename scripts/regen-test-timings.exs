# Rebuilds scripts/test-timings.tsv, the cost table scripts/partition-files.exs
# balances on. Reads `mix test --slowest-modules` output on stdin:
#
#     mix test --max-cases 8 --slowest-modules 400 \
#       | elixir scripts/regen-test-timings.exs
#
# Run it when the partitions visibly drift apart — the partition jobs print
# their predicted cost, so a manifest that has gone stale shows up there rather
# than having to be remembered. Absolute numbers do not need to match CI; only
# the ratios between files matter to the bucketing.

input = IO.read(:stdio, :eof)

# ExUnit prints the module, then its file on the next line. Paths come through
# app-relative for apps/fountain and absolute for ee/, so both are normalised
# back to repo-relative here.
#
# The ee/ branch mirrors the one in scripts/partition-files.exs and exists for
# the same reason: ee/ lives at the repo root while its tests belong to
# apps/fountain. IF EE/ EVER MOVES OR IS EXTRACTED, both branches go, along
# with `test_paths` in apps/fountain/mix.exs. The guard below — every parsed
# path must exist on disk — is what turns a half-finished change into a loud
# failure here rather than a quietly shrunken manifest.
entries =
  Regex.scan(~r/^\s*[A-Za-z0-9_.]+ \((\d+(?:\.\d+)?)ms\)\n\s*\[([^\]]+)\]/m, input)
  |> Enum.map(fn [_, ms, path] ->
    path =
      cond do
        String.starts_with?(path, "test/") ->
          "apps/fountain/" <> path

        String.contains?(path, "/ee/test/") ->
          "ee/test/" <> List.last(String.split(path, "/ee/test/"))

        true ->
          path
      end

    {path, ms |> String.to_float() |> round()}
  end)
  |> Enum.reduce(%{}, fn {path, ms}, acc -> Map.update(acc, path, ms, &(&1 + ms)) end)

if map_size(entries) == 0 do
  IO.puts(:stderr, "no module timings found on stdin — was --slowest-modules passed?")
  System.halt(1)
end

missing = Enum.reject(Map.keys(entries), &File.exists?/1)

if missing != [] do
  IO.puts(:stderr, "these parsed paths do not exist, so the normalisation is wrong:")
  Enum.each(Enum.take(missing, 5), &IO.puts(:stderr, "  " <> &1))
  System.halt(1)
end

body =
  entries
  |> Enum.sort()
  |> Enum.map_join("\n", fn {path, ms} -> "#{path}\t#{ms}" end)

File.write!("scripts/test-timings.tsv", """
# Measured cost per test file, milliseconds. Regenerate with:
#   mix test --max-cases 8 --slowest-modules 400 | elixir scripts/regen-test-timings.exs
# Consumed by scripts/partition-files.exs. A file missing from here is costed
# at the median rather than zero, so adding tests degrades balance gently
# instead of silently loading one partition.
#{body}
""")

IO.puts("wrote scripts/test-timings.tsv: #{map_size(entries)} files")
