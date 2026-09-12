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

  # 2646 → 2641. `start_provision_watchdog/2` moved out to
  # `Fountain.Conversations.ProvisionWatchdog`, taking 81 lines with it and
  # putting the file at 2565. The pin is not lowered to 2565: the number has
  # not stopped moving. The #1766/#1767 campaign is measured at +68 across
  # its 26 open PRs, landing the file at 2633, and the remaining 8 lines are
  # for the two of them still in review rounds. Tighten this to the file's
  # real length in a follow-up once that campaign has landed.
  @pin 2641

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
