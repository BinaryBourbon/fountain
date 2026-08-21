# Assigns test files to partitions by measured cost, and prints one partition's
# files, newline-separated, for scripts/test-partition.sh to pass to mix test.
#
# WHY NOT `mix test --partitions`: it deals files out by their index in the
# sorted file list, so a partition's contents — and therefore its runtime — are
# arbitrary, and adding or renaming ONE test file reshuffles every partition.
# Observed spread across six partitions was 24.5s to 66.5s for the same suite,
# and CI's imbalance wandered from 1.65x to 2.39x over a handful of unrelated
# merges with nothing having regressed. The slowest partition is the critical
# path, so that spread is pure waste.
#
# THE COST MODEL is the part worth understanding. A partition's wall time is
# NOT the sum of its modules: ExUnit runs every `async: true` module first,
# up to max_cases at a time, and only then runs the sync ones ONE AT A TIME.
# So a sync module costs its full duration and an async one costs roughly
# duration/max_cases. Bucketing on raw totals would balance the wrong number
# and leave the sync-heavy partition just as slow — which is exactly the state
# this replaces, where the worst partition was 48.4s of sync against 10.4s of
# async.
#
# Regenerate the manifest with:
#     mix test --max-cases 8 --slowest-modules 400
# and feed the output through scripts/regen-test-timings.exs.
#
# Usage: elixir scripts/partition-files.exs <partition> <total-partitions>

[partition, total] = System.argv() |> Enum.map(&String.to_integer/1)

if partition < 1 or partition > total do
  IO.puts(:stderr, "partition #{partition} is outside 1..#{total}")
  System.halt(1)
end

# Matches ExUnit's own default: schedulers_online * 2, capped the way CI runs it.
max_cases = 8

files =
  ["apps/fountain/test", "ee/test"]
  |> Enum.flat_map(&Path.wildcard(&1 <> "/**/*_test.exs"))
  |> Enum.sort()

if files == [] do
  IO.puts(:stderr, "no test files found")
  System.halt(1)
end

timings =
  case File.read("scripts/test-timings.tsv") do
    {:ok, body} ->
      for line <- String.split(body, "\n", trim: true),
          not String.starts_with?(line, "#"),
          [path, ms] <- [String.split(line, "\t")],
          into: %{},
          do: {path, String.to_integer(ms)}

    _ ->
      %{}
  end

# A file is async only if it says so. Case templates that force `async: false`
# (ConversationServerCase, SandboxConformanceCase) simply never match, which is
# the answer we want: treat anything not proven async as serial.
async? = fn path ->
  case File.read(path) do
    {:ok, body} -> String.contains?(body, "async: true")
    _ -> false
  end
end

# An unmeasured file — someone added a test and did not regenerate — costs the
# median rather than zero, so it cannot silently pile onto one partition.
known = Map.values(timings)
median = if known == [], do: 500, else: Enum.sort(known) |> Enum.at(div(length(known), 2))

weighted =
  files
  |> Enum.map(fn path ->
    ms = Map.get(timings, path, median)
    cost = if async?.(path), do: ms / max_cases, else: ms * 1.0
    {path, cost}
  end)
  |> Enum.sort_by(fn {path, cost} -> {-cost, path} end)

# Longest-processing-time-first: repeatedly give the next most expensive file to
# whichever partition is cheapest so far. Deterministic given the same inputs,
# which matters — every partition job runs this independently and they must all
# agree on the same assignment.
buckets =
  Enum.reduce(weighted, Map.new(1..total, &{&1, {0.0, []}}), fn {path, cost}, acc ->
    {idx, {total_cost, paths}} = Enum.min_by(acc, fn {i, {c, _}} -> {c, i} end)
    Map.put(acc, idx, {total_cost + cost, [path | paths]})
  end)

{_cost, mine} = Map.fetch!(buckets, partition)

if mine == [] do
  IO.puts(:stderr, "partition #{partition}/#{total} was assigned no files")
  System.halt(1)
end

if System.get_env("PARTITION_DEBUG") do
  for i <- 1..total do
    {c, p} = Map.fetch!(buckets, i)

    IO.puts(
      :stderr,
      "  partition #{i}: #{Float.round(c / 1000, 1)}s predicted, #{length(p)} files"
    )
  end
end

# `mix test` resolves explicit paths against apps/fountain, because that is the
# app whose test_paths (["test", "../../ee/test"]) own every test in the
# umbrella. Repo-relative paths are what the manifest and this script reason
# about; these are what mix will actually accept.
#
# The `../../ee/` hop exists only because ee/ sits at the repo root while its
# tests belong to apps/fountain — decisions/0010 and its addendum own that
# arrangement. IF EE/ EVER MOVES OR IS EXTRACTED: delete the ee clause below,
# and the matching normalisation in scripts/regen-test-timings.exs, and check
# apps/fountain/mix.exs `test_paths` at the same time — all three encode the
# same layout, and nothing fails loudly if only one of them is updated. The
# symptom would be a partition silently missing files, which the >0-tests guard
# in test-partition.sh catches only if a partition empties completely.
mine
|> Enum.sort()
|> Enum.map(fn
  "apps/fountain/" <> rest -> rest
  "ee/" <> rest -> "../../ee/" <> rest
  other -> other
end)
|> Enum.each(&IO.puts/1)
