defmodule Managoat.Sandbox.Sprites.ProtocolContractTest do
  @moduledoc """
  A contract test against the `sprites` SDK's wire decoding, not against our
  own code.

  Sprites frames a finished command as stream id 3 followed by a **one-byte**
  exit code. The fork we pinned until #880 decoded that field as a 4-byte
  big-endian integer, so no real exit frame ever matched: every one fell
  through to `{:unknown, _}`, was dropped, and the socket's later close made
  `Sprites.Command` synthesise a `0`. Every one of the 533 exit codes Fountain
  had ever recorded was that synthetic zero — failing setup scripts and failed
  clones included.

  Nothing in Fountain can catch that regression, because `Sprites.exec/4` is
  correct either way; it faithfully reports whatever the SDK hands it. So the
  guard belongs here, on the dependency, where a future pin bump that reverts
  the decoding fails the build instead of silently disarming every exit code.
  """

  use ExUnit.Case, async: true

  alias Sprites.Protocol

  @exit_id 3

  describe "exit frames decode as a single byte" do
    test "every code a process can actually exit with round-trips" do
      # 128 is git's `fatal:` (a silently-successful clone in #880); 255 is the
      # top of the POSIX range, which is why one byte is enough.
      for code <- [0, 1, 42, 127, 128, 130, 255] do
        assert Protocol.decode(<<@exit_id, code>>) == {:exit, code},
               "exit code #{code} did not decode; a dropped exit frame reports as success"
      end
    end

    test "a trailing byte does not stop the code being read" do
      assert Protocol.decode(<<@exit_id, 42, 0, 0, 0>>) == {:exit, 42}
    end

    test "an empty payload is the only case that defaults to 0" do
      assert Protocol.decode(<<@exit_id>>) == {:exit, 0}
    end

    test "a non-zero exit never decodes as :unknown" do
      refute match?({:unknown, _}, Protocol.decode(<<@exit_id, 1>>))
    end
  end

  describe "the other stream ids still mean what the adapter assumes" do
    test "stdout and stderr carry their payload verbatim" do
      assert Protocol.decode(<<1, "out">>) == {:stdout, "out"}
      assert Protocol.decode(<<2, "err">>) == {:stderr, "err"}
    end
  end
end
