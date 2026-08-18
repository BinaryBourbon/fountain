defmodule FountainWeb.TeamPresenter do
  @moduledoc """
  What a teammate looks like from the outside — presence and the roster
  preview — computed once, for both the `/team` LiveView and `/api/team`.

  Both are views over `Fountain.Team.list_teammates/1`; the presence reads
  the conversation and sandbox rows, the preview reads the last turn's
  events through the same parser the chat bubbles use, so the roster line
  and the thread agree on what the teammate last said.
  """

  import FountainWeb.ConversationsLive.Chat, only: [chat_assistant_reply: 2]

  alias Fountain.Conversations

  @typedoc "`state` is the vocabulary a client switches on; `label` is what a human reads."
  @type presence :: %{state: String.t(), label: String.t()}

  @presence_states ~w(working starting online asleep away failed offline)
  @preview_kinds ~w(you them typing)

  @doc "Every `state` `presence/1` can answer — the wire enum."
  def presence_states, do: @presence_states

  @doc "Every `kind` the JSON preview can carry — the wire enum."
  def preview_kinds, do: @preview_kinds

  @doc """
  What the teammate's computer is doing, from the conversation and its
  sandbox. States: `working`, `starting`, `online`, `asleep`, `away`,
  `failed`, `offline`.
  """
  @spec presence(map()) :: presence()
  def presence(%{status: "running"}), do: %{state: "working", label: "working"}

  def presence(%{status: "pending"}),
    do: %{state: "starting", label: "starting computer"}

  def presence(%{status: "idle", sandbox: %{status: s}}) when s in ["ready", "starting"],
    do: %{state: "online", label: "online"}

  def presence(%{status: "idle", sandbox: %{status: "suspended"}}),
    do: %{state: "asleep", label: "asleep · wakes on message"}

  def presence(%{status: "idle"}), do: %{state: "away", label: "away · wakes on message"}
  def presence(%{status: "failed"}), do: %{state: "failed", label: "offline · failed"}
  def presence(_), do: %{state: "offline", label: "offline · new computer on message"}

  @doc """
  The roster's one-line preview of a teammate's thread: `nil` when there are
  no messages, `:typing` while a turn is in flight, else `{:you, prompt}` or
  `{:them, reply}` for the last turn. One query per teammate (the last
  turn's events) — cheap for a team-sized list.
  """
  @spec preview(map()) :: nil | :typing | {:you | :them, String.t()}
  def preview(%{last_turn: nil}), do: nil

  def preview(%{last_turn: %{status: status}}) when status in ["pending", "running"],
    do: :typing

  def preview(%{last_turn: turn, conversation: conv}) do
    # Ownership: `turn` belongs to a conversation from the tenant-scoped
    # Team.list_teammates that built this entry.
    reply =
      turn.id
      |> Conversations._unsafe_list_turn_log_events()
      |> chat_assistant_reply(conv.runtime)

    if reply == "", do: {:you, turn.prompt}, else: {:them, reply}
  end
end
