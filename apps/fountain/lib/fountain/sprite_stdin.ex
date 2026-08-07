defmodule Fountain.SpriteStdin do
  @moduledoc """
  Writing to a sprite command's stdin without the write taking the caller down.

  `Sprites.write/2` is specced `:ok | {:error, term()}`, but underneath it is a
  bare `GenServer.call/2` into the `Sprites.Command` process — and that process
  stops `:normal` the moment the runtime's exit frame arrives. A call landing
  after that exits the *caller*; it does not return `{:error, _}`. The library
  has a graceful clause for the still-alive-but-disconnected case
  (`{:error, :not_connected}`), so recovery was clearly intended; the
  dead-process case is the gap, and it is the one that reaches us.

  That is #603. A runtime that exits before the prompt is written — a bad flag,
  a missing binary, an immediate non-zero exit, an OOM kill at startup — took
  the whole `ConversationServer` down. The supervisor restarted it, the
  restarted server found its sandbox already `ready` and so took the reattach
  branch, and the turn ended up orphaned behind a `list_sessions` error that
  named nothing real. Against the spritzer emulator, whose exec is one-shot,
  this lost roughly half of all turns.

  `write/2` turns that exit into the `{:error, reason}` its callers already
  know how to handle. The real fix belongs upstream in
  [`sprites-ex`](https://github.com/ravi-hq/sprites-ex), where `write_stdin/2`
  should honour its own `@spec`; until then every stdin write in this app goes
  through here.
  """

  @typedoc """
  Why the prompt never reached the runtime.

  `:command_exited` means the command process was gone — the runtime exited
  before it read stdin. Anything else is the library's own error term, or a
  call that timed out.
  """
  @type error :: :command_exited | {:write_failed, term()} | term()

  @doc """
  Write `data` to `command`'s stdin.

  Same contract as `Sprites.write/2`, except that it is actually total: a
  command process that has already stopped yields `{:error, :command_exited}`
  rather than exiting the caller.
  """
  @spec write(Sprites.Command.t(), iodata()) :: :ok | {:error, error()}
  def write(command, data) do
    Sprites.write(command, data)
  catch
    # GenServer.call re-wraps the callee's exit reason together with the call
    # that provoked it. `:normal` is the command process stopping mid-call (the
    # runtime's exit frame won the race); `:noproc` is it having stopped before
    # the call was even sent. Both mean the same thing to a caller: there is no
    # runtime left to read this prompt.
    :exit, {reason, {GenServer, :call, _args}} when reason in [:normal, :noproc, :shutdown] ->
      {:error, :command_exited}

    # A timeout or any other exit is not the #603 shape, but killing the caller
    # is no better an answer for it either.
    :exit, {reason, {GenServer, :call, _args}} ->
      {:error, {:write_failed, reason}}

    :exit, reason ->
      {:error, {:write_failed, reason}}
  end
end
