defmodule Fountain.Conversations.Identity do
  @moduledoc """
  Which conversation a process inside a sandbox belongs to — carried by the
  process, never by the disk.

  A sandbox row has been `has_many :conversations` since the first migration,
  and `Fountain.Team.open_fresh_conversation/3` has produced a second
  conversation on one row in production since #840. What stayed 1:1 was the
  identity: `FOUNTAIN_TOKEN` (the per-conversation callback key) and
  `FOUNTAIN_CONVERSATION_ID` were written to `/home/sprite/.env` — one path,
  rewritten on every provision and reattach — and a reattach after a deploy
  bound to the *head* of the sandbox's session list, because nothing on a
  session said whose it was. Two conversations mid-turn on one machine across
  a deploy would have streamed one agent into the other's transcript
  (ADR 0023, survey items 1 and 2).

  Three rules, all enforced here:

    * **Identity is process env.** `disk_env/1` strips the per-conversation
      pairs before the env file is written; the same pairs still reach every
      spawn through `env:`, so the agent's tools inherit them exactly as
      before. What a `source .env` in a setup script loses is the callback
      token, which it had no business holding — the file is for environment
      and vault values, which are the same for every conversation on the
      machine.

    * **A session names its conversation.** `tag_command/3` wraps the spawn as
      `env FOUNTAIN_CONVERSATION_ID=<id> <cmd> <args…>`, so the tag is in the
      command line every provider reports for a detachable session
      (`Fountain.Sandbox.Session.command`) *and* the process gets the variable
      from the same line. No argv is added to the adapter itself, which would
      reject it.

    * **Reattach matches on the tag.** `pick_session/2` takes the session
      tagged with this conversation, ignores one tagged with another, and —
      only while sessions spawned before this module existed are still alive —
      falls back to an untagged head. That fallback is what keeps the deploy
      that ships this from orphaning every turn in flight; it is not a
      contract, and a session that carries someone else's tag is never taken.
  """

  alias Fountain.Sandbox.Session

  @tag_key "FOUNTAIN_CONVERSATION_ID"

  # Per-conversation pairs. `FOUNTAIN_BASE_URL` stays on disk: it is the same
  # for every conversation and a setup script may legitimately read it.
  #
  # The broker proxy address carries the conversation's session token (ADR
  # 0019 §5), so it is per-conversation too: on disk it would be a
  # cross-conversation read of a credential that brokers another tenant's
  # vault. `Fountain.Broker.process_only_keys/0` names the variables.
  @process_only [@tag_key, "FOUNTAIN_TOKEN", "TRACEPARENT"] ++ Fountain.Broker.process_only_keys()

  @tag_re ~r/(?:^|\s)FOUNTAIN_CONVERSATION_ID=([0-9a-fA-F-]{36})(?:\s|$)/

  @doc "The env var that tags a session with its conversation."
  @spec tag_key() :: String.t()
  def tag_key, do: @tag_key

  @doc """
  The keys that never reach the shared env file.
  """
  @spec process_only_keys() :: [String.t()]
  def process_only_keys, do: @process_only

  @doc """
  The subset of a sprite env that belongs on the machine's disk: everything
  except the per-conversation identity.
  """
  @spec disk_env([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def disk_env(sprite_env) when is_list(sprite_env) do
    Enum.reject(sprite_env, fn {k, _v} -> to_string(k) in @process_only end)
  end

  @doc """
  Wrap a command so its session is tagged with `conv_id` and the process sees
  the variable: `{"env", ["FOUNTAIN_CONVERSATION_ID=<id>", cmd | args]}`.
  """
  @spec tag_command(String.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def tag_command(conv_id, cmd, args) when is_binary(conv_id) and is_binary(cmd) do
    {"env", ["#{@tag_key}=#{conv_id}", cmd | args]}
  end

  @doc """
  The conversation a session was spawned for, read from its command line, or
  `nil` for a session spawned before tagging existed (or by something else).
  """
  @spec conversation_id(Session.t()) :: String.t() | nil
  def conversation_id(%Session{command: command}) when is_binary(command) do
    case Regex.run(@tag_re, command, capture: :all_but_first) do
      [id] -> String.downcase(id)
      _ -> nil
    end
  end

  def conversation_id(%Session{}), do: nil

  @doc """
  The session a reattaching server for `conv_id` should bind to.

    * `{:tagged, session}` — a session carrying this conversation's tag. The
      newest one if there are several (a peer that died mid-handshake can
      leave an older idle adapter behind; the caller already stops those).
    * `{:untagged, session}` — no session carries our tag, but one carries no
      tag at all. Transitional: only sessions spawned before this tagging
      existed look like this.
    * `:none` — nothing to bind to. Sessions tagged with *another*
      conversation are never offered.
  """
  @spec pick_session([Session.t()], String.t()) ::
          {:tagged, Session.t()} | {:untagged, Session.t()} | :none
  def pick_session(sessions, conv_id) when is_list(sessions) and is_binary(conv_id) do
    wanted = String.downcase(conv_id)

    {ours, others} =
      Enum.split_with(sessions, fn s -> conversation_id(s) == wanted end)

    untagged = Enum.filter(others, &is_nil(conversation_id(&1)))

    cond do
      ours != [] -> {:tagged, newest(ours)}
      untagged != [] -> {:untagged, hd(untagged)}
      true -> :none
    end
  end

  # Providers report `created_at`; where they do not, list order stands.
  defp newest(sessions) do
    if Enum.all?(sessions, &match?(%DateTime{}, &1.created_at)) do
      Enum.max_by(sessions, & &1.created_at, DateTime)
    else
      hd(sessions)
    end
  end
end
