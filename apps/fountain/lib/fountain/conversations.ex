defmodule Fountain.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn, TurnImage}
  alias Fountain.Repo

  # ── sandboxes ─────────────────────────────────────────────────────────────

  def list_sandboxes do
    Repo.all(from s in Sandbox, order_by: [desc: s.inserted_at])
  end

  @doc "List active sandboxes across all tenants (admin use only)."
  def list_sandboxes_admin do
    alias Fountain.Accounts.User

    Repo.all(
      from s in Sandbox,
        where: s.status not in ["terminated", "failed"],
        order_by: [desc: s.inserted_at],
        left_join: u in User,
        on: u.id == s.user_id,
        preload: [user: u, conversations: []]
    )
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

  @doc """
  WARNING: returns conversations across all tenants. Only call from
  admin-restricted paths or internal state lookups where ownership has
  already been verified upstream.
  """
  def _unsafe_list_conversations do
    Repo.all(
      from c in Conversation,
        order_by: [desc: c.inserted_at, desc: c.id],
        preload: [:sandbox, :agent, turns: ^first_turn_query()]
    )
  end

  @doc """
  Conversations the operator might still want to interact with: anything
  not in a terminal state. Ordered with active sessions on top
  (`running` > `idle`) and most-recent first within a status bucket.
  Used for the left-nav "active conversations" list.
  """
  def list_active_conversations do
    Repo.all(
      from c in Conversation,
        where: c.status not in ["terminated", "completed", "failed"],
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
  WARNING: returns conversations across all tenants ordered by activity.
  Admin/internal use only. User-facing code must use the arity-1 variant
  that takes user_id.
  """
  def _unsafe_list_conversations_by_activity do
    Repo.all(
      from c in Conversation,
        order_by: [desc: c.updated_at, desc: c.id],
        preload: [:agent, turns: ^first_turn_query()]
    )
  end

  @doc "List conversations for `user_id`, ordered by most recently active."
  def list_conversations_by_activity(user_id) when is_binary(user_id) do
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

    {:ok, uuid} = Ecto.UUID.dump(conversation_id)
    %{rows: rows} = Repo.query!(sql, [uuid])

    Enum.map(rows, fn [id, source, status, parent_id] ->
      %{
        id: load_uuid!(id),
        source: source,
        status: status,
        parent_id: load_uuid(parent_id)
      }
    end)
  end

  defp load_uuid!(bin) when is_binary(bin) do
    {:ok, str} = Ecto.UUID.load(bin)
    str
  end

  defp load_uuid(nil), do: nil
  defp load_uuid(bin), do: load_uuid!(bin)

  @doc """
  Conversations whose `ConversationServer` would have been running at the
  time of a clean BEAM stop: status `idle` or `running`, with a fully-
  provisioned (`ready`) sandbox.
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

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only —
  user-facing endpoints must use the arity-2 variant that takes user_id.
  """
  def _unsafe_get_conversation(id) do
    Conversation
    |> Repo.get(id)
    |> Repo.preload([:sandbox, :agent, :vault])
  end

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only.
  """
  def _unsafe_get_conversation!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:sandbox, :agent, :vault])
  end

  @doc "Get conversation scoped to user. Returns nil on wrong owner or missing id."
  def get_conversation(id, user_id) when is_binary(user_id) do
    case Repo.get_by(Conversation, id: id, user_id: user_id) do
      nil -> nil
      conv -> Repo.preload(conv, [:sandbox, :agent, :vault])
    end
  end

  @doc "Get conversation scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_conversation!(id, user_id) when is_binary(user_id) do
    Conversation
    |> Repo.get_by!(id: id, user_id: user_id)
    |> Repo.preload([:sandbox, :agent, :vault])
  end

  @doc "List conversations for user, ordered by most recently active."
  def list_conversations(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Conversation,
        where: c.user_id == ^user_id,
        order_by: [desc: c.updated_at, desc: c.id],
        preload: [:agent, turns: ^first_turn_query()]
    )
  end

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
    _ = Fountain.Conversations.ConversationServer.terminate(id)
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
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          turn_id: Ecto.UUID.dump!(turn_id),
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
    # Microsecond precision so the LiveView can compute stage durations
    # under 1s (provision steps run in tens of ms).
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

  # `streams` is a list of allowed stream identifiers. We accept the
  # three values that show up in log_events: `"stdout"`, `"stderr"`, and
  # `"stage"` (the synthetic name we give to `kind: "stage"` events,
  # which don't have a real `stream` column value). `nil`/empty list =
  # no filter.
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
        # All values were unknown; return nothing rather than everything.
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

  alias Fountain.Agents
  alias Fountain.Conversations.ConversationServer

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`              — agent to run
    - `prompt`                — optional first prompt (sends turn 1 immediately)
    - `sprite_name`           — optional override; defaults to "fountain-<short-user-id>-<short-id>"
    - `vault_id`              — optional vault whose secrets override the env's
    - `source`                — optional; one of "ui", "api", "agent" (default "api")
    - `parent_conversation_id` — optional; UUID of the conversation that spawned this one
  """
  def start_conversation(%{"agent_id" => agent_id, "user_id" => user_id} = attrs)
      when is_binary(user_id) do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, runtime_module} <- Fountain.Runtimes.for_runtime(agent.runtime),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id),
         {:ok, sandbox} <-
           create_sandbox(%{
             environment_id: agent.environment_id,
             sprite_name: attrs["sprite_name"] || "fountain-#{tenant_prefix(user_id)}-#{short_id()}",
             status: "pending",
             user_id: user_id
           }),
         {:ok, conv} <-
           create_conversation(%{
             sandbox_id: sandbox.id,
             agent_id: agent.id,
             vault_id: vault_id,
             user_id: user_id,
             runtime: agent.runtime,
             status: "pending",
             source: attrs["source"] || "api",
             parent_conversation_id: attrs["parent_conversation_id"]
           }) do
      {:ok, _pid} =
        Horde.DynamicSupervisor.start_child(
          Fountain.ConversationSupervisor,
          {ConversationServer,
           [
             conversation_id: conv.id,
             sandbox_id: sandbox.id,
             runtime_module: runtime_module,
             initial_prompt: attrs["prompt"]
           ]}
        )

      result = _unsafe_get_conversation!(conv.id)

      if result.parent_conversation_id do
        root_id = get_root_conversation_id(result.id)
        broadcast_graph_update(root_id)
      end

      {:ok, result}
    else
      nil -> {:error, :not_found}
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

    {:ok, uuid} = Ecto.UUID.dump(conversation_id)

    case Repo.query!(sql, [uuid]) do
      %{rows: [[root_id]]} ->
        {:ok, str_id} = Ecto.UUID.load(root_id)
        str_id

      _ ->
        conversation_id
    end
  end

  defp broadcast_graph_update(root_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "conversations:graph:#{root_id}",
      {:graph_updated}
    )
  end

  defp first_turn_query, do: from(t in Turn, where: t.turn_number == 1)

  defp short_id, do: Ecto.UUID.generate() |> binary_part(0, 8)

  defp tenant_prefix(user_id) when is_binary(user_id), do: binary_part(user_id, 0, 8)

  defp resolve_vault_id(nil, _user_id), do: {:ok, nil}
  defp resolve_vault_id("", _user_id), do: {:ok, nil}

  defp resolve_vault_id(id, user_id) when is_binary(id) and is_binary(user_id) do
    case Fountain.Vaults.get_vault(id, user_id) do
      nil -> {:error, :vault_not_found}
      vault -> {:ok, vault.id}
    end
  end

  @doc """
  Resume a conversation whose ConversationServer is gone (e.g. after a
  BEAM restart, or in the gap between Rehydrator runs).

  Strategy:
  1. If the existing sandbox is `ready` and the sprite is still alive at
     sprites.dev, start a fresh `ConversationServer` pointing at it. The
     server will go through reattach mode and pick up any running
     detachable session.
  2. Otherwise, provision a fresh sprite, mark the old sandbox
     terminated, and start the server pointing at the new sandbox.
     `claude --resume` keeps the chat via the persisted
     `runtime_session_id`.

  Returns `{:error, :gone}` if the conversation is in a terminal status
  (`terminated`, `failed`, `completed`) — those don't auto-resume.
  """
  def wake_conversation(conv_id, initial_prompt \\ nil) do
    with %Conversation{} = conv <- _unsafe_get_conversation(conv_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         %Agents.Agent{} = agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:error, :no_agent},
         {:ok, runtime_module} <- Fountain.Runtimes.for_runtime(conv.runtime) do
      case maybe_reuse_sandbox(conv) do
        {:reuse, sandbox_id} ->
          start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt)

        :create_new ->
          create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # Probe the existing sandbox: if it's `ready` and sprites.dev confirms
  # the sprite still exists, we can reattach without provisioning a new
  # one. Otherwise, fall through to creating a fresh sandbox.
  defp maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  defp maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case get_sandbox(sandbox_id) do
      %{status: "ready", sprite_name: name} when is_binary(name) ->
        client = Fountain.SpritesClient.get!()

        case Sprites.get_sprite(client, name) do
          {:ok, _info} -> {:reuse, sandbox_id}
          _ -> :create_new
        end

      _ ->
        :create_new
    end
  end

  defp start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
    with {:ok, _pid} <-
           Horde.DynamicSupervisor.start_child(
             Fountain.ConversationSupervisor,
             {ConversationServer,
              [
                conversation_id: conv.id,
                sandbox_id: sandbox_id,
                runtime_module: runtime_module,
                initial_prompt: initial_prompt
              ]}
           ) do
      {:ok, _unsafe_get_conversation!(conv.id)}
    end
  end

  defp create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt) do
    with {:ok, new_sandbox} <-
           create_sandbox(%{
             environment_id: agent.environment_id,
             sprite_name: "fountain-#{tenant_prefix(conv.user_id)}-#{short_id()}",
             status: "pending",
             user_id: conv.user_id
           }),
         _ <- mark_old_sandbox_terminated(conv.sandbox_id),
         {:ok, conv} <-
           update_conversation(conv, %{sandbox_id: new_sandbox.id, status: "pending"}) do
      start_conversation_server(conv, new_sandbox.id, runtime_module, initial_prompt)
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
