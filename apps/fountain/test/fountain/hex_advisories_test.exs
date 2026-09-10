Code.require_file("../../../../config/hex_advisories.exs", __DIR__)

defmodule Fountain.HexAdvisoriesTest do
  use ExUnit.Case, async: true

  alias Fountain.Build.HexAdvisories

  @root Path.expand("../../../..", __DIR__)
  @lock File.read!(Path.join(@root, "mix.lock"))

  test "the reviewed artifact acknowledges only the Decimal advisory" do
    assert HexAdvisories.for_lock(Path.join(@root, "mix.lock")) == ["EEF-CVE-2026-32686"]
  end

  for {name, old, new} <- [
        {"version", "\"3.1.1\"", "\"2.4.1\""},
        {"inner checksum", "430d87b04011ce6cbd4fd205be758311a81f87d552d40904abd00f015935b1d0",
         "changed"},
        {"outer checksum", "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6",
         "changed"},
        {"repository", "[], \"hexpm\", \"c5f25", "[], \"another-repository\", \"c5f25"}
      ] do
    @old old
    @new new
    test "a changed #{name} drops the acknowledgment" do
      changed = String.replace(@lock, @old, @new)
      assert changed != @lock
      assert audit_lock(changed) == []
    end
  end

  test "a future package release requires another review" do
    assert audit_lock(String.replace(@lock, "\"3.1.1\"", "\"3.1.2\"")) == []
  end

  test "a missing or malformed lock does not authorize an acknowledgment" do
    assert HexAdvisories.for_lock(Path.join(Fountain.TmpDir.mkdir!("hex-ack"), "absent")) == []
    assert audit_lock("not a lock file") == []
    assert audit_lock("%{}") == []
  end

  test "duplicate entries cannot conceal a different effective artifact" do
    line = @lock |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "  \"decimal\":"))

    duplicate =
      String.replace(@lock, line, line <> "\n" <> String.replace(line, "3.1.1", "2.4.1"))

    assert audit_lock(duplicate) == []
  end

  test "lock contents are parsed without executing code" do
    marker = Path.join(Fountain.TmpDir.mkdir!("hex-ack"), "executed")
    assert audit_lock("File.write!(#{inspect(marker)}, \"unexpected\")\n" <> @lock) == []
    refute File.exists?(marker)
  end

  test "the installed Decimal rejects the advisory's extreme exponents by default" do
    for input <- ["1e1000000000", "1e-1000000000"] do
      assert Decimal.parse(input) == :error
      assert Decimal.cast(input) == :error
      assert_raise Decimal.Error, fn -> Decimal.new(input) end
    end
  end

  defp audit_lock(source) do
    path = Path.join(Fountain.TmpDir.mkdir!("hex-ack"), "mix.lock")
    File.write!(path, source)
    HexAdvisories.for_lock(path)
  end
end
