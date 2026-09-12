defmodule Fountain.Conversations.ConversationServerSizeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `ConversationServer` only shrinks.

  Tracker #1369 refactors the server by subtraction: each sub-issue moves a
  function family into a module under `Fountain.Conversations.*` and lowers
  `@pin` to the file's new length in the same PR. The pin is the file's line
  count on `main` at the last move, so a change that makes the file longer
  fails here and has to say why.

  The shape is the docs-style allowlist that only shrinks (#911): the number
  is not a target, it is a record of where the file is, and the only edit it
  accepts is downward. Lower it when you move something out; never raise it.

  **A stack in flight does not move it.** The pin is the length on `main`, and
  a number measured against a branch is stale the moment any link below it
  grows the file, which is what review rounds do. #1565 lowered it mid-stack to
  the tip's exact length, left zero headroom, and went red two rounds later
  when a fix four PRs down added lines. Land the shrink first, then lower the
  pin in a follow-up, when the number has stopped moving.

  That is what this pin is mid-way through. #1749 and #1751 each lowered it
  to their own tip's exact length while the #1766/#1767 campaign was in
  flight below them, which left `main` at 2646 with the file also at 2646 —
  no room for the next line anyone adds, and a campaign already ~68 lines
  over it with nothing red anywhere (#2032). Each of its PRs is green
  against its own base, the merges conflict on nothing, and `count <= @pin`
  only fails at the moment the last one lands.
  """

  # 2641 → 2549. The reattachment family — `reattach_running_turn/1`,
  # `reap_orphan_sessions/1`, `attempt_session_attach/4`, `mark_orphan/3` and
  # `find_running_turn/1` — moved to `Fountain.Conversations.Reattachment`,
  # which already owned the ACP half of the same path. That takes 163 lines
  # out and puts the file at 2466.
  #
  # The pin is not lowered to 2466: the #1766/#1767 campaign is still in
  # flight below it. Measured today across its 18 open PRs, by diffing each
  # chain tip against the base it forks from rather than summing per-PR
  # counts, its remaining net is **+73** to this file — #1975 +10, the
  # #1978→#2007 chain +58, #1977 +5, #1979 +0 — landing the file at 2539.
  # (#2037 measured +68 a day ago; two review rounds on #1981 and #1982 have
  # moved it since, which is exactly the drift this moduledoc warns about.)
  #
  # 2549 is that 2539 plus 10 lines for the rounds still to come. Tighten it
  # to the file's real length in a follow-up once the campaign has landed.
  @pin 2549

  @server "apps/fountain/lib/fountain/conversations/conversation_server.ex"

  test "the server is no longer than the pin" do
    root = Path.expand("../../../../..", __DIR__)
    lines = root |> Path.join(@server) |> File.read!() |> String.split("\n")
    # `String.split/2` yields one more element than there are newlines, so
    # this is `wc -l` for a file that ends in a newline.
    count = length(lines) - 1

    assert count <= @pin,
           "#{@server} is #{count} lines, over the pin of #{@pin}. " <>
             "The server only shrinks (#1369): move the new code into a " <>
             "Fountain.Conversations.* module rather than raising the pin."
  end
end
