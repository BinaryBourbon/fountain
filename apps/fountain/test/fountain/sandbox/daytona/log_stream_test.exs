defmodule Fountain.Sandbox.Daytona.LogStreamTest do
  use ExUnit.Case, async: true

  alias Fountain.Sandbox.Daytona.LogStream

  describe "demux/2 — the 3-byte channel markers" do
    test "splits a mixed chunk into stdout and stderr segments" do
      data = <<1, 1, 1>> <> "out" <> <<2, 2, 2>> <> "err" <> <<1, 1, 1>> <> "more"

      assert {[{:stdout, "out"}, {:stderr, "err"}, {:stdout, "more"}], :stdout, <<>>} =
               LogStream.demux(data, :stdout)
    end

    test "data before any marker rides the current channel" do
      assert {[{:stderr, "tail"}], :stderr, <<>>} = LogStream.demux("tail", :stderr)
    end

    test "a marker split across chunks is carried, not corrupted" do
      # Chunk one ends mid-marker; the carry must be prepended to chunk two.
      {segments, stream, carry} = LogStream.demux("out" <> <<2, 2>>, :stdout)
      assert segments == [{:stdout, "out"}]
      assert carry == <<2, 2>>

      assert {[{:stderr, "err"}], :stderr, <<>>} =
               LogStream.demux(carry <> <<2>> <> "err", stream)
    end

    test "marker-like bytes inside data survive when not a full marker" do
      # A lone 0x01 followed by ordinary data is content, not a channel switch.
      data = <<1>> <> "x"
      assert {[{:stdout, <<1, ?x>>}], :stdout, <<>>} = LogStream.demux(data, :stdout)
    end

    test "empty input is empty output" do
      assert {[], :stdout, <<>>} = LogStream.demux(<<>>, :stdout)
    end
  end
end
