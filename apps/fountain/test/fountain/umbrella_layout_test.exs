defmodule Fountain.UmbrellaLayoutTest do
  @moduledoc """
  The rules a component library in this umbrella has to keep (decisions/0037).

  Every `apps/managoat_*` directory is a library on its way out of this
  repository: Apache-2.0, `Managoat.*` namespace, and no reach back into
  Fountain. The umbrella's own dependency resolution enforces the direction
  `fountain -> library`; it does nothing about a library that *mentions*
  `Fountain.SomeModule` in a string or a comment, reads `:fountain`
  configuration, or emits telemetry under Fountain's prefix, and each of
  those would come back as a surprise on graduation day. This test walks the
  directories so the miss lands here, on the PR that introduced it.

  It also pins the mechanics that silently degrade rather than fail: a
  library whose `mix.exs` is not `COPY`d in the Dockerfile's deps layer
  breaks the image build (which CI does not run, #884 shape), and one that
  `apps/fountain` does not list as an in-umbrella dep compiles fine and is
  never part of the release.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @apps Path.join(@root, "apps")
  @dockerfile Path.join(@root, "Dockerfile")
  @fountain_mix Path.join(@apps, "fountain/mix.exs")

  @libraries @apps
             |> Path.join("managoat_*")
             |> Path.wildcard()
             |> Enum.filter(&File.dir?/1)
             |> Enum.sort()

  test "there is at least one library app, or this test guards nothing" do
    assert @libraries != [], "no apps/managoat_* directory; decisions/0037 says there is one"
  end

  for lib <- @libraries do
    name = Path.basename(lib)

    describe "apps/#{name}" do
      @lib lib
      @name name

      test "carries the files a library ships with" do
        for file <- ~w(mix.exs LICENSE README.md .formatter.exs test/test_helper.exs) do
          assert File.exists?(Path.join(@lib, file)), "apps/#{@name}/#{file} is missing"
        end
      end

      test "is Apache-2.0, in its LICENSE and in its package metadata" do
        assert @lib |> Path.join("LICENSE") |> File.read!() |> String.contains?("Apache License")
        mix = @lib |> Path.join("mix.exs") |> File.read!()
        assert mix =~ ~r/licenses:\s*\["Apache-2\.0"\]/, "apps/#{@name}/mix.exs package.licenses"
      end

      test "is an in_umbrella dependency of apps/fountain" do
        assert File.read!(@fountain_mix) =~ ~r/\{:#{@name},\s*in_umbrella:\s*true\}/,
               "apps/fountain/mix.exs does not list {:#{@name}, in_umbrella: true}"
      end

      test "has its mix.exs COPYd in the Dockerfile deps layer" do
        expected = "COPY apps/#{@name}/mix.exs ./apps/#{@name}/mix.exs"

        assert File.read!(@dockerfile) =~ expected,
               "Dockerfile lacks `#{expected}`; the image build's mix deps.get would fail"
      end

      test "defines only Managoat.* modules" do
        for {file, src} <- sources(@lib, "lib") do
          for [_, mod] <- Regex.scan(~r/^\s*defmodule\s+([A-Z][\w.]*)/m, src) do
            assert String.starts_with?(mod, "Managoat."),
                   "#{rel(file)} defines #{mod}; library modules are Managoat.*"
          end
        end
      end

      test "does not reach back into Fountain" do
        offenders =
          for {file, src} <- sources(@lib, ["lib", "test"]),
              {label, re} <- [
                {"a Fountain.* / FountainWeb.* reference", ~r/\bFountain(Web)?\./},
                {":fountain configuration", ~r/(get_env|fetch_env!?|put_env)\(\s*:fountain\b/},
                {"[:fountain, ...] telemetry", ~r/\[\s*:fountain\s*,/}
              ],
              Regex.match?(re, src),
              do: "#{rel(file)}: #{label}"

        assert offenders == [],
               Enum.join(["a library may not depend on Fountain:" | offenders], "\n  ")
      end
    end
  end

  defp sources(lib, dirs) do
    dirs
    |> List.wrap()
    |> Enum.flat_map(&Path.wildcard(Path.join([lib, &1, "**/*.{ex,exs}"])))
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp rel(path), do: Path.relative_to(path, @root)
end
