defmodule AgentOnDemand.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  alias AgentOnDemand.Conversations.{Conversation, LogEvent, Sandbox, Turn, TurnImage}
  alias AgentOnDemand.Repo

  # ── sandboxes ─────────────────────────────────────────────────────────────

  def list_sandboxes do
    Repo.all(from s in Sandbox, order_by: [desc: s.inserted_at])
  end

  def get_sandbox(id), do: Repo.get(Sandbox, id)
  def get_sandbox!(id), do: Repo.get!(Sandbox, id)

  def create_sandbox(attrs) do
    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert()
  end

  def update_sandbox(%Sandbox{} = sandbox, attrs) do
    sandbox
    |> Sandbox.changeset(attrs)
    |> Repo.update()
  end

  # ── conversations ─────────────────────────────────────────────────────────

  def list_conversations(user_id) do
    Repo.all(
      from c in Conversation,
        where: c.user_id == ^user_id,
        order_by: [desc: c.inserted_at, desc: c.id],
        preload: [:sandbox, :agent, turns: ^first_turn_query()]
    )
  end

  @doc """
  Non-terminal conversations for the given user, ordered with active
  sessions on top (`running` > `idle`) and most-recent first within a
  status bucket. Used for the left-nav active conversations list.
  """
  def list_active_conversations(user_id) do
    Repo.all(
      from c in Conversation,
        where:
          c.user_id == ^user_id and
            c.status not in ["terminated", "completed", "failed"],
        order_by: [
          asc:
            fragment(
              "CASE ? WHEN 'running' THEN 0 WHEN 'idle' THEN 1 ELSE 2 END",
              c.status
            ),
          desc: c.inserted_at,
          desc: c.id
        ],
        preload: [:agent, turns: ^first_turn_query()]
    )
  end

  @doc """
  All conversations for the given user ordered by most recently active
  first (`updated_at desc`). Used for the left-nav conversations list.
  """
  def list_conversations_by_activity(user_id) do
    Repo.all(
      from c in Conversation,
        where: c.user_id == ^user_id,
        order_by: [desc: c.updated_at, desc: c.id],
        preload: [:agent, turns: ^first_turn_query()]
    )
  end

  @doc """
  Returns all conversations in the same spawn tree as `conversation_id`,
  including ancestors up to the root and all their descendants.

  Each entry is a map with keys: :id, :source, :status, :parent_id

  Returns `[]` when `conversation_id` does not exist.
  """
  def get_conversation_tree(conversation_id) do
    sql = """
    WITH RECURSIVE
    ancestors(id, parent_conversation_id) AS (
      SELECT id, parent_conversation_id FROM conversations WHERE id = $1
      UNION ALL
      SELECT c.id, c.parent_conversation_id FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
    ),
    root_row AS (
      SELECT id FROM ancestors WHERE parent_conversation_id IS NULL LIMIT 1
    ),
    tree(id, source, status, parent_id) AS (
      SELECT c.id, c.source, c.status, c.parent_conversation_id
      FROM conversations c, root_row r WHERE c.id = r.id
      UNION ALL
      SELECT c.id, c.source, c.status, c.parent_conversation_id
      FROM conversations c
      INNER JOIN tree t ON c.parent_conversation_id = t.id
    )
    SELECT id, source, status, parent_id FROM tree
    """

    %{rows: rows} = Repo.query!(sql, [conversation_id])

    Enum.map(rows, fn [id, source, status, parent_id] ->
      %{id: id, source: source, status: status, parent_id: parent_id}
    end)
  end

  @doc """
  Conversations whose `ConversationServer` would have been running at the
  time of a clean BEAM stop: status `idle` or `running`, with a fully-
  provisioned (`ready`) sandbox. Not user-scoped — this is a system/admin
  function called by the Rehydrator on boot.
  """
  def list_resumable_conversations do
    Repo.all(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where: c.status in ["idle", "running"] and s.status == "ready",
        preload: [:sandbox]
    )
  end

  @doc "Returns the conversation if it belongs to user_id, otherwise nil."
  def get_conversation(id, user_id) do
    Conversation
    |> Repo.get_by(id: id, user_id: user_id)
    |> maybe_preload_conversation()
  end

  @doc """
  Returns the conversation. Raises Ecto.NoResultsError if not found or
  the conversation does not belong to user_id (cross-tenant access → 404).
  """
  def get_conversation!(id, user_id) do
    Conversation
    |> Repo.get_by!(id: id, user_id: user_id)
    |> Repo.preload([:sandbox, :agent, :vault])
  end

  @doc "Internal fetch by id only. Use only from ConversationServer (already user-scoped)."
  def get_conversation_internal!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:sandbox, :agent, :vault])
  end

  defp maybe_preload_conversation(nil), do: nil
  defp maybe_preload_conversation(conv), do: Repo.preload(conv, [:sandbox, :agent, :vault])

  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conv, attrs) do
    conv
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Best-effort terminate the running ConversationServer (destroys the sprite
  if alive), then delete the conversation row. Cascades to turns and log
  events via the FK.
  """
  def delete_conversation(%Conversation{id: id} = conv) do
    _ = AgentOnDemand.Conversations.ConversationServer.terminate(id)
    Repo.delete(conv)
  end

  # ── turns ─────────────────────────────────────────────────────────────────

  def list_turns(conversation_id) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.turn_number],
        preload: [images: ^from(i in TurnImage, order_by: [asc: i.position])]
    )
  end

  def list_turns_with_images(conversation_id) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.turn_number],
        preload: [images: ^from(i in TurnImage, order_by: [asc: i.position])]
    )
  end

  def get_turn_by_conversation(turn_id, conversation_id) do
    Repo.get_by(Turn, id: turn_id, conversation_id: conversation_id)
  end

  def insert_turn_images(_turn_id, []), do: {:ok, []}

  def insert_turn_images(turn_id, images) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      images
      |> Enum.with_index()
      |> Enum.map(fn {%{media_type: mt, data: data}, idx} ->
        %{
          id: Ecto.UUID.generate(),
          turn_id: turn_id,
          position: idx,
          media_type: mt,
          data: data,
          inserted_at: now
        }
      end)

    {count, _} = Repo.insert_all("turn_images", rows)
    {:ok, count}
  end

  def get_turn_image(turn_id, position) do
    Repo.get_by(TurnImage, turn_id: turn_id, position: position)
  end

  def next_turn_number(conversation_id) do
    last =
      Repo.one(
        from t in Turn,
          where: t.conversation_id == ^conversation_id,
          select: max(t.turn_number)
      )

    (last || 0) + 1
  end

  def create_turn(attrs) do
    %Turn{}
    |> Turn.changeset(attrs)
    |> Repo.insert()
  end

  def update_turn(%Turn{} = turn, attrs) do
    turn
    |> Turn.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Mark any `running` turns for the given conversation as `interrupted`.
  Used during reattach: a BEAM restart orphaned whatever turn was in
  flight, and we can't know its outcome — mark it so the user gets a
  clear signal instead of a permanently-stuck status.
  """
  def mark_orphaned_turns_interrupted(conversation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(
        from(t in Turn,
          where: t.conversation_id == ^conversation_id and t.status == "running"
        ),
        set: [status: "interrupted", ended_at: now]
      )

    n
  end

  # ── log events ────────────────────────────────────────────────────────────

  @doc """
  Insert a log event. Returns the inserted struct (with integer `:id`,
  used as the SSE event id).
  """
  def log!(attrs) do
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now())

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Stream persisted log events for a conversation, ordered by id.
  Optionally start after a given event id (for SSE Last-Event-ID resume).
  """
  def stream_log_events(conversation_id, after_id \\ 0) do
    from(e in LogEvent,
      where: e.conversation_id == ^conversation_id and e.id > ^after_id,
      order_by: [asc: e.id]
    )
    |> Repo.stream(max_rows: 100)
  end

  def list_log_events(conversation_id, after_id \\ 0, opts \\ []) do
    base =
      from e in LogEvent,
        where: e.conversation_id == ^conversation_id and e.id > ^after_id,
        order_by: [asc: e.id]

    base
    |> apply_streams_filter(Keyword.get(opts, :streams))
    |> Repo.all()
  end

  defp apply_streams_filter(query, nil), do: query
  defp apply_streams_filter(query, []), do: query

  defp apply_streams_filter(query, streams) when is_list(streams) do
    real_streams = Enum.filter(streams, &(&1 in ["stdout", "stderr"]))
    include_stage? = "stage" in streams

    cond do
      include_stage? and real_streams != [] ->
        from e in query,
          where: e.kind == "stage" or e.stream in ^real_streams

      include_stage? ->
        from e in query, where: e.kind == "stage"

      real_streams != [] ->
        from e in query, where: e.stream in ^real_streams

      true ->
        from e in query, where: false
    end
  end

  @doc """
  Sum the byte sizes of persisted output events for a turn, by stream.
  Used by ConversationServer on reattach to know how many bytes of
  replayed output to skip before persisting fresh, post-disconnect data.
  """
  def output_bytes_by_stream(conversation_id, turn_id) do
    from(e in LogEvent,
      where:
        e.conversation_id == ^conversation_id and
          e.turn_id == ^turn_id and
          e.kind == "output" and
          not is_nil(e.stream),
      group_by: e.stream,
      select: {e.stream, fragment("COALESCE(SUM(LENGTH(?)), 0)", e.data)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ── high-level lifecycle ──────────────────────────────────────────────────

  alias AgentOnDemand.Agents
  alias AgentOnDemand.Conversations.ConversationServer

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`              — agent to run (must belong to user_id)
    - `prompt`                — optional first prompt (sends turn 1 immediately)
    - `vault_id`              — optional vault (must belong to user_id)
    - `source`                — optional; one of "ui", "api", "agent" (default "api")
    - `parent_conversation_id` — optional; UUID of the conversation that spawned this one

  Cross-tenant guard: if `agent_id` or `vault_id` belong to a different
  user, the function returns `{:error, :not_found}` rather than :forbidden
  to avoid leaking existence.
  """
  def start_conversation(%{"agent_id" => agent_id} = attrs, user_id) do
    with %Agents.Agent{user_id: ^user_id} = agent <-
           Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, runtime_module} <- AgentOnDemand.Runtimes.for_runtime(agent.runtime),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id),
         {:ok, sandbox} <-
           create_sandbox(%{
             environment_id: agent.environment_id,
             # Sandbox naming per decision 0005: fountain-conv-<short-id>
             sprite_name: attrs["sprite_name"] || "fountain-conv-#{short_id()}",
             status: "pending",
             user_id: user_id
           }),
         {:ok, conv} <-
           create_conversation(%{
             sandbox_id: sandbox.id,
             agent_id: agent.id,
             vault_id: vault_id,
             runtime: agent.runtime,
             status: "pending",
             source: attrs["source"] || "api",
             parent_conversation_id: attrs["parent_conversation_id"],
             user_id: user_id
           }) do
      {:ok, _pid} =
        Horde.DynamicSupervisor.start_child(
          AgentOnDemand.ConversationSupervisor,
          {ConversationServer,
           [
             conversation_id: conv.id,
             sandbox_id: sandbox.id,
             runtime_module: runtime_module,
             initial_prompt: attrs["prompt"],
             user_id: user_id
           ]}
        )

      result = get_conversation!(conv.id, user_id)

      if result.parent_conversation_id do
        root_id = get_root_conversation_id(result.id)
        broadcast_graph_update(root_id)
      end

      {:ok, result}
    else
      nil -> {:error, :not_found}
      # Pattern match on user_id failed — agent exists but belongs to another user.
      %Agents.Agent{} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp get_root_conversation_id(conversation_id) do
    sql = """
    WITH RECURSIVE ancestors(id, parent_conversation_id) AS (
      SELECT id, parent_conversation_id FROM conversations WHERE id = $1
      UNION ALL
      SELECT c.id, c.parent_conversation_id FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
    )
    SELECT id FROM ancestors WHERE parent_conversation_id IS NULL LIMIT 1
    """

    case Repo.query!(sql, [conversation_id]) do
      %{rows: [[root_id]]} -> root_id
      _ -> conversation_id
    end
  end

  defp broadcast_graph_update(root_id) do
    Phoenix.PubSub.broadcast(
      AgentOnDemand.PubSub,
      "conversations:graph:#{root_id}",
      {:graph_updated}
    )
  end

  defp first_turn_query, do: from(t in Turn, where: t.turn_number == 1)

  defp short_id, do: Ecto.UUID.generate() |> binary_part(0, 8)

  defp resolve_vault_id(nil, _user_id), do: {:ok, nil}
  defp resolve_vault_id("", _user_id), do: {:ok, nil}

  defp resolve_vault_id(id, user_id) when is_binary(id) do
    case AgentOnDemand.Vaults.get_vault(id, user_id) do
      nil -> {:error, :vault_not_found}
      vault -> {:ok, vault.id}
    end
  end

  @doc """
  Resume a conversation whose ConversationServer is gone (e.g. after a
  BEAM restart, or in the gap between Rehydrator runs).
  """
  def wake_conversation(conv_id, user_id, initial_prompt \\ nil) do
    with %Conversation{} = conv <- get_conversation(conv_id, user_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         %Agents.Agent{} = agent <-
           (conv.agent_id && Agents.get_agent(conv.agent_id, user_id)) || {:error, :no_agent},
         {:ok, runtime_module} <- AgentOnDemand.Runtimes.for_runtime(conv.runtime) do
      case maybe_reuse_sandbox(conv) do
        {:reuse, sandbox_id} ->
          start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt, user_id)

        :create_new ->
          create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt, user_id)
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  defp maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case get_sandbox(sandbox_id) do
      %{status: "ready", sprite_name: name} when is_binary(name) ->
        client = AgentOnDemand.SpritesClient.get!()

        case Sprites.get_sprite(client, name) do
          {:ok, _info} -> {:reuse, sandbox_id}
          _ -> :create_new
        end

      _ ->
        :create_new
    end
  end

  defp start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt, user_id) do
    with {:ok, _pid} <-
           Horde.DynamicSupervisor.start_child(
             AgentOnDemand.ConversationSupervisor,
             {ConversationServer,
              [
                conversation_id: conv.id,
                sandbox_id: sandbox_id,
                runtime_module: runtime_module,
                initial_prompt: initial_prompt,
                user_id: user_id
              ]}
           ) do
      {:ok, get_conversation!(conv.id, user_id)}
    end
  end

  defp create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt, user_id) do
    with {:ok, new_sandbox} <-
           create_sandbox(%{
             environment_id: agent.environment_id,
             sprite_name: "fountain-conv-#{short_id()}",
             status: "pending",
             user_id: user_id
           }),
         _ <- mark_old_sandbox_terminated(conv.sandbox_id),
         {:ok, conv} <-
           update_conversation(conv, %{sandbox_id: new_sandbox.id, status: "pending"}) do
      start_conversation_server(conv, new_sandbox.id, runtime_module, initial_prompt, user_id)
    end
  end

  defp assert_resumable(%Conversation{status: s}) when s in ~w(terminated failed completed) do
    {:error, :gone}
  end

  defp assert_resumable(_), do: :ok

  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    case get_sandbox(sandbox_id) do
      nil ->
        :ok

      sb when sb.status in ["terminated", "failed"] ->
        :ok

      sb ->
        update_sandbox(sb, %{
          status: "terminated",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end
end
