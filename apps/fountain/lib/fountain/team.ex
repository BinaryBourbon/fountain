defmodule Fountain.Team do
  @moduledoc """
  The team: the agents a user talks to as people, one persistent
  conversation each.

  A teammate is not a new kind of thing. It is a conversation — one per
  agent — bound to the reserved channel `"fountain:team"`, exactly the way
  a Buzz channel binds a conversation through `channel_id` (#774). Adding an
  agent to the team opens that conversation, which provisions the agent its
  own sandbox: its computer. Messaging the teammate is `send_prompt` on that
  conversation, and `ConversationServer.send_prompt/4` already wakes a
  suspended or reaped sandbox, so the teammate is always reachable. Only a
  `terminated`/`failed` conversation is past resuming; the next message opens
  a fresh one under the same binding — the agent gets a new computer, and the
  team list keeps showing the same teammate.

  Removing a teammate terminates the live conversation and clears the binding
  on every conversation this agent had under it, so the rows stay in the
  user's history (`/conversations`) but leave the team.

  Every function is tenant-scoped by `user_id`; the `_unsafe_` reads inside
  are legitimate because they follow the scoped fetch in the same function.
  """

  import Ecto.Query, warn: false

  alias Fountain.{Agents, Audit, Conversations, Repo}
  alias Fountain.Conversations.{Conversation, ConversationServer, Turn}

  @channel "fountain:team"

  @doc "The reserved `channel_id` that marks a conversation as a teammate's."
  def channel, do: @channel

  @doc """
  One entry per agent on the team, most recently active first.

  Each entry is `%{agent: %Agent{}, conversation: %Conversation{}, last_turn:
  %Turn{} | nil}` — the conversation is the newest live one for that agent,
  or, when none is live, the newest terminated/failed one (so the last
  transcript still shows). The conversation carries `turn_count` and
  `last_active_at`; `last_turn` is what the list previews.
  """
  def list_teammates(user_id) when is_binary(user_id) do
    convs =
      user_id
      |> Conversations.list_channel_conversations(@channel)
      |> Enum.reject(&is_nil(&1.agent))
      |> Enum.group_by(& &1.agent_id)
      |> Enum.map(fn {_agent_id, convs} -> pick_current(convs) end)

    last_turns = last_turns_by_conversation(Enum.map(convs, & &1.id))

    convs
    |> Enum.map(&%{agent: &1.agent, conversation: &1, last_turn: Map.get(last_turns, &1.id)})
    |> Enum.sort_by(& &1.conversation.last_active_at, {:desc, DateTime})
  end

  # The newest turn of each conversation in one query (DISTINCT ON). The ids
  # come from the tenant-scoped listing above, which is what scopes this.
  defp last_turns_by_conversation([]), do: %{}

  defp last_turns_by_conversation(conv_ids) do
    from(t in Turn,
      where: t.conversation_id in ^conv_ids,
      distinct: t.conversation_id,
      order_by: [asc: t.conversation_id, desc: t.turn_number]
    )
    |> Repo.all()
    |> Map.new(&{&1.conversation_id, &1})
  end

  @doc "The teammate for `agent_id`, or nil when that agent is not on the team."
  def get_teammate(user_id, agent_id) when is_binary(user_id) and is_binary(agent_id) do
    user_id
    |> list_teammates()
    |> Enum.find(&(&1.agent.id == agent_id))
  end

  # `list_channel_conversations/2` returns newest-first, so the first live one
  # (or, failing that, the first at all) is the current binding.
  defp pick_current(convs) do
    Enum.find(convs, &live?/1) || hd(convs)
  end

  @doc "Whether the teammate's current conversation can still take a message."
  def live?(%Conversation{status: status}), do: status not in ["terminated", "failed"]

  @doc """
  Add `agent_id` to the team: open its conversation (and so its sandbox).

  Idempotent — an agent already on the team gets its existing conversation
  back and nothing is recorded, since nothing changed. Returns `{:ok, conv}`
  or the `start_conversation/2` error (`:not_found`, `:subscription_required`,
  `{:sandbox_quota_exceeded, _}`, ...). `opts` is audit attribution.
  """
  def add_teammate(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    attrs = %{
      "agent_id" => agent_id,
      "user_id" => user_id,
      "channel_id" => @channel,
      "source" => "ui"
    }

    case Conversations.start_or_resume_conversation(attrs, opts) do
      {:ok, conv, :created} ->
        record(user_id, "team.member.added", conv, opts)
        {:ok, conv}

      {:ok, conv, :resumed} ->
        {:ok, conv}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Remove `agent_id` from the team.

  Terminates the live conversation (its sandbox goes with it) and unbinds
  every conversation this agent had under the team channel — the rows stay in
  the user's history, they just stop being the teammate. `{:error, :not_found}`
  when the agent is not on the team; nothing is recorded then.
  """
  def remove_teammate(user_id, agent_id, opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) do
    case get_teammate(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %{conversation: conv} ->
        # `audit: false`: the removal below is the thing the user asked for;
        # the terminate is how it is carried out, not a second action.
        if live?(conv), do: ConversationServer.terminate_conversation(conv.id, audit: false)

        {_n, _} =
          Repo.update_all(
            from(c in Conversation,
              where:
                c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^@channel
            ),
            set: [channel_id: nil]
          )

        record(user_id, "team.member.removed", conv, opts)
        :ok
    end
  end

  @doc """
  Send `text` (and optional decoded `images`) to the teammate for `agent_id`.

  Goes through `ConversationServer.send_prompt/4`, which wakes a parked or
  reaped sandbox itself. When the current conversation is past resuming
  (`terminated`/`failed`, or the server answers `:gone`), a fresh conversation
  is opened under the same binding with this as its first prompt — the agent
  gets a new computer and the message is not lost.

  Returns `{:ok, conv}` with the conversation the message went to, or the
  `send_prompt`/`start_conversation` error unchanged (`:busy`,
  `:provisioning`, `:subscription_required`, ...).
  """
  def send_message(user_id, agent_id, text, images \\ [], opts \\ [])
      when is_binary(user_id) and is_binary(agent_id) and is_binary(text) do
    case get_teammate(user_id, agent_id) do
      nil ->
        {:error, :not_found}

      %{conversation: conv} ->
        if live?(conv) do
          case ConversationServer.send_prompt(conv.id, text, images, opts) do
            :ok -> {:ok, Conversations.get_conversation(conv.id, user_id) || conv}
            {:error, :gone} -> start_fresh(user_id, agent_id, text, images, opts)
            {:error, _} = err -> err
          end
        else
          start_fresh(user_id, agent_id, text, images, opts)
        end
    end
  end

  # A new conversation under the team binding, seeded with the message. Not
  # `start_or_resume`: we are here precisely because the bound conversation
  # cannot be resumed, and `find_channel_conversation` would agree — but
  # saying so directly keeps the intent readable.
  defp start_fresh(user_id, agent_id, text, images, opts) do
    Conversations.start_conversation(
      %{
        "agent_id" => agent_id,
        "user_id" => user_id,
        "channel_id" => @channel,
        "source" => "ui",
        "prompt" => text,
        "images" => images
      },
      opts
    )
  end

  @doc "Agents of `user_id` that are not on the team yet — the add picker."
  def list_addable_agents(user_id) when is_binary(user_id) do
    on_team = user_id |> list_teammates() |> MapSet.new(& &1.agent.id)

    user_id
    |> Agents.list_agents([])
    |> Enum.reject(&MapSet.member?(on_team, &1.id))
  end

  # Membership events. Named after the team, not the conversation: the
  # conversation events (`conversation.created`, `.terminated`) still fire
  # underneath where they apply, and describe the sandbox side of the same
  # action; these describe the team side.
  defp record(user_id, action, %Conversation{} = conv, opts) do
    Audit.record(%{
      user_id: user_id,
      action: action,
      resource_type: "conversation",
      resource_id: conv.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "agent_id" => conv.agent_id,
        "agent_name" => conv.agent && conv.agent.name
      }
    })
  end
end
