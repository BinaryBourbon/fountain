defmodule Fountain.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn, TurnImage}
  alias Fountain.Repo

  # ── on the _unsafe_ prefix ────────────────────────────────────────────────
  #
  # Every function here that does not scope by `user_id` carries the prefix,
  # including the ones whose callers happen to check ownership first. That is
  # the point of a convention: the reader of a call site should not have to go
  # and find out.
  #
  # Several of these were unprefixed until #182 — `get_sandbox/1`,
  # `list_turns/1`, `list_log_events/3` and friends. No call site was wrong, but
  # nothing marked them either, so the audit that makes `_unsafe_` useful had a
  # hole exactly where it mattered least visibly.
  #
  # A legitimate caller is one of: admin surfaces behind `require_admin`,
  # system-level sweeps like the rehydrator and the reaper, or a GenServer that
  # has already established ownership. Anything user-facing wants the scoped
  # variant.

  # ── sandboxes ──────────────────────────────────────────────────────────────────────────

  @doc "List active sandboxes across all tenants (admin use only)."
  def _unsafe_list_sandboxes_admin do
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

  def _unsafe_get_sandbox(id), do: Repo.get(Sandbox, id)
  def _unsafe_get_sandbox!(id), do: Repo.get!(Sandbox, id)

  @doc """
  Load any tenant's conversation for the admin support view (#446).

  Returns the conversation with owner/agent/sandbox preloaded plus turn and
  log-event **counts** — deliberately not the turns or log events themselves.
  The admin surface renders metadata only (status, timing, exit codes); prompt
  and output content stay tenant-private. `_unsafe_list_turn_summaries_admin/1`
  carries the same rule.
  """
  def _unsafe_get_conversation_admin(id) do
    case Repo.get(Conversation, id) do
      nil ->
        nil

      conv ->
        conv = Repo.preload(conv, [:user, :agent, :sandbox])

        turn_count =
          Repo.aggregate(from(t in Turn, where: t.conversation_id == ^id), :count)

        log_event_count =
          Repo.aggregate(from(le in LogEvent, where: le.conversation_id == ^id), :count)

        %{conversation: conv, turn_count: turn_count, log_event_count: log_event_count}
    end
  end

  @doc """
  Turn metadata for the admin support view: numbers, statuses, exit codes and
  timing — never `prompt`. The select list is the privacy boundary; keep
  content columns out of it.
  """
  def _unsafe_list_turn_summaries_admin(conversation_id, limit \\ 100) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [desc: t.turn_number],
        limit: ^limit,
        select: %{
          id: t.id,
          turn_number: t.turn_number,
          status: t.status,
          exit_code: t.exit_code,
          started_at: t.started_at,
          ended_at: t.ended_at,
          inserted_at: t.inserted_at
        }
    )
  end

  @doc """
  Support teardown of any tenant's sandbox, from the admin panel.

  A conversation with a live `ConversationServer` is terminated through the
  server, which destroys the sprite and ends the conversation — that is what
  stopping a runaway agent means. A sandbox with no live server just has its
  row marked terminated: the conversation stays resumable (next prompt gets a
  fresh sandbox, same session) and the reaper destroys the sprite on its next
  pass, the same split `SandboxReaper.expire_abandoned_sandboxes/0` uses.
  """
  def _unsafe_reap_sandbox(sandbox_id) do
    alias Fountain.Conversations.ConversationServer

    case _unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :not_found}

      %Sandbox{status: s} when s in ["terminated", "failed"] ->
        {:ok, :already_terminal}

      sandbox ->
        sandbox = Repo.preload(sandbox, :conversations)
        live = Enum.filter(sandbox.conversations, &ConversationServer.whereis(&1.id))

        if live == [] do
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          {:ok, _} = update_sandbox(sandbox, %{status: "terminated", terminated_at: now})
          {:ok, :released}
        else
          Enum.each(live, &ConversationServer.terminate(&1.id))
          {:ok, :terminated}
        end
    end
  end

  @doc """
  Reap every active sandbox belonging to `user_id` — the suspension path
  (#287). `_unsafe_` per the tenant contract: unscoped, and legitimate callers
  are admin-driven (`Accounts.suspend_user/1` behind `require_admin`).

  Best-effort by design: each sandbox reaps independently and a failure moves
  on — suspension must not be blocked by one wedged sprite; `SandboxReaper`
  sweeps stragglers. Returns the number of sandboxes reaped.
  """
  def _unsafe_reap_all_for_user(user_id) when is_binary(user_id) do
    from(s in Sandbox,
      where: s.user_id == ^user_id and s.status in ^Fountain.Quotas.active_statuses(),
      select: s.id
    )
    |> Repo.all()
    |> Enum.count(fn id -> match?({:ok, _}, _unsafe_reap_sandbox(id)) end)
  end

  def create_sandbox(attrs) do
    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a sandbox, emitting usage events on billable transitions.

  Every sandbox status change in the system goes through here — fresh
  provisioning, the wake path, and the terminate-when-the-server-is-already-dead
  path in `ConversationServer.terminate/1`. Metering at this choke point means a
  new caller cannot forget to record usage, which is how `Billing.emit/5` ended
  up with no call sites at all despite being documented, schema'd and tested.
  """
  def update_sandbox(%Sandbox{} = sandbox, attrs) do
    was = sandbox.status

    with {:ok, updated} <- sandbox |> Sandbox.changeset(attrs) |> Repo.update() do
      record_sandbox_usage(was, updated)
      {:ok, updated}
    end
  end

  @billable_terminal ~w(terminated failed)

  # Transitions only: update_sandbox/2 is called repeatedly with the same status
  # in places, and double-counting a sandbox would overstate a bill.
  defp record_sandbox_usage(was, %Sandbox{status: "ready"} = sandbox) when was != "ready" do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_provisioned",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name}
    )
  end

  defp record_sandbox_usage(was, %Sandbox{status: status} = sandbox)
       when status in @billable_terminal and was not in @billable_terminal do
    # A sandbox that dies before reaching "ready" never emitted
    # sandbox_provisioned, but it is about to emit sandbox_terminated with a
    # duration — so the conversation count and the sandbox minutes on the
    # billing page would diverge for exactly the accounts where provisioning
    # is failing. Record the attempt under its own event type so the two
    # sides can be reconciled.
    if was != "ready" do
      Fountain.Billing.record_usage(
        sandbox.user_id,
        "sandbox_provision_failed",
        sandbox.id,
        "sandbox",
        %{"sprite_name" => sandbox.sprite_name, "status_before_failure" => was}
      )
    end

    # `failed` counts too: a sprite that died mid-provision still ran, and was
    # still billed by Sprites. Recording only clean terminations would
    # understate cost precisely when something is going wrong.
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_terminated",
      sandbox.id,
      "sandbox",
      %{
        "duration_ms" => sandbox_duration_ms(sandbox),
        "final_status" => status
      }
    )
  end

  defp record_sandbox_usage(_was, _sandbox), do: :ok

  defp sandbox_duration_ms(%Sandbox{inserted_at: nil}), do: 0

  defp sandbox_duration_ms(%Sandbox{inserted_at: started} = sandbox) do
    ended = sandbox.terminated_at || DateTime.utc_now()
    ended |> DateTime.diff(started, :millisecond) |> max(0)
  end

  # ── conversations ─────────────────────────────────────────────────────────────────────

  @doc """
  Conversations the operator might still want to interact with: anything
  not in a terminal state. Ordered with active sessions on top
  (`running` > `idle`) and most-recent first within a status bucket.
  Used for the left-nav "active conversations" list.
  """
  def _unsafe_list_active_conversations do
    Repo.all(
      from c in Conversation,
        where: c.status not in ["terminated", "failed"],
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
  List conversations for `user_id`, ordered by most recently active.

  Populates the `turn_count` virtual field on each conversation by LEFT
  JOINing a subquery that counts turns per conversation. This avoids an
  N+1 and keeps the result a plain list of `%Conversation{}` structs.

  Only `kind: "output"` log events count toward `last_active_at` —
  `kind: "stage"` events (reattach, sandbox lifecycle) are excluded so
  that reconnects don't artificially bump a conversation to the top.
  """
  def list_conversations_by_activity(user_id) when is_binary(user_id) do
    turn_counts =
      from t in Turn,
        group_by: t.conversation_id,
        select: %{conversation_id: t.conversation_id, count: count(t.id)}

    last_turn_at =
      from t in Turn,
        group_by: t.conversation_id,
        select: %{conversation_id: t.conversation_id, last_at: max(t.inserted_at)}

    last_log_at =
      from le in LogEvent,
        where: le.kind == "output",
        group_by: le.conversation_id,
        select: %{conversation_id: le.conversation_id, last_at: max(le.inserted_at)}

    Repo.all(
      from c in Conversation,
        where: c.user_id == ^user_id and c.status != "terminated",
        left_join: tc in subquery(turn_counts),
        on: tc.conversation_id == c.id,
        left_join: lt in subquery(last_turn_at),
        on: lt.conversation_id == c.id,
        left_join: ll in subquery(last_log_at),
        on: ll.conversation_id == c.id,
        order_by: [
          desc:
            fragment(
              "GREATEST(COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), ? AT TIME ZONE 'UTC')",
              ll.last_at,
              c.inserted_at,
              lt.last_at,
              c.inserted_at,
              c.inserted_at
            )
        ],
        select: %{
          c
          | turn_count: fragment("COALESCE(?, 0)", tc.count),
            last_active_at:
              fragment(
                "GREATEST(COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), ? AT TIME ZONE 'UTC')",
                ll.last_at,
                c.inserted_at,
                lt.last_at,
                c.inserted_at,
                c.inserted_at
              )
        }
    )
    |> Repo.preload([:agent, turns: first_turn_query()])
  end

  @doc """
  Returns all conversations in the same spawn tree as `conversation_id`,
  scoped to `user_id`.

  Each entry is a map with keys: :id, :source, :status, :parent_id

  Returns `[]` when the conversation does not exist or belongs to someone else.

  Every reference to `conversations` carries the tenant predicate. Without it
  the recursion walks straight across tenant boundaries, which leaked
  conversation ids, sources and statuses in both directions: a conversation
  parented onto another tenant's conversation pulled their whole tree into this
  view, and put this one into theirs.

  The root is the furthest *reachable* ancestor rather than the one with a NULL
  parent. For clean data those are the same node. They differ only where a
  foreign parent link already exists in the data, and picking the boundary node
  degrades to "show the part of the tree you own" instead of returning nothing.
  """
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters
  # ($1/$2 UUIDs dumped above); nothing user-controlled is interpolated.
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters
  # ($1/$2 UUIDs dumped below); nothing user-controlled is interpolated.
  def get_conversation_tree(conversation_id, user_id) when is_binary(user_id) do
    sql = """
    WITH RECURSIVE
    ancestors(id, parent_conversation_id, depth) AS (
      SELECT id, parent_conversation_id, 0
      FROM conversations WHERE id = $1 AND user_id = $2
      UNION ALL
      SELECT c.id, c.parent_conversation_id, a.depth + 1
      FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
      -- depth bound: parent links are client-supplied, and a cycle would
      -- otherwise spin this CTE forever.
      WHERE c.user_id = $2 AND a.depth < 100
    ),
    root_row AS (
      SELECT id FROM ancestors ORDER BY depth DESC LIMIT 1
    ),
    tree(id, source, status, parent_id, depth) AS (
      SELECT c.id, c.source, c.status, c.parent_conversation_id, 0
      FROM conversations c, root_row r
      WHERE c.id = r.id AND c.user_id = $2
      UNION ALL
      SELECT c.id, c.source, c.status, c.parent_conversation_id, t.depth + 1
      FROM conversations c
      INNER JOIN tree t ON c.parent_conversation_id = t.id
      WHERE c.user_id = $2 AND t.depth < 100
    )
    SELECT id, source, status, parent_id FROM tree
    """

    with {:ok, conv_uuid} <- Ecto.UUID.dump(conversation_id),
         {:ok, user_uuid} <- Ecto.UUID.dump(user_id) do
      %{rows: rows} = Repo.query!(sql, [conv_uuid, user_uuid])

      Enum.map(rows, fn [id, source, status, parent_id] ->
        %{
          id: load_uuid!(id),
          source: source,
          status: status,
          parent_id: load_uuid(parent_id)
        }
      end)
    else
      _ -> []
    end
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
  def _unsafe_list_resumable_conversations do
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

  @doc """
  List conversations for user, ordered by most recently updated.

  Pass `roots_only: true` to exclude child conversations (those with a
  `parent_conversation_id`). Useful for hiding agent-spawned sub-conversations
  from the index when the user only wants to see top-level sessions.

  Populates the `last_active_at` virtual field using `kind: "output"` log
  events only — stage events (reconnects, lifecycle) are excluded so
  reconnects don't produce false unread indicators.
  """
  def list_conversations(user_id, opts \\ []) when is_binary(user_id) do
    roots_only = Keyword.get(opts, :roots_only, false)

    base = from(c in annotated_query(user_id), order_by: [desc: c.updated_at, desc: c.id])

    query =
      if roots_only do
        where(base, [conv: c], is_nil(c.parent_conversation_id))
      else
        base
      end

    Repo.all(query)
    |> Repo.preload([:agent, turns: first_turn_query()])
  end

  @doc """
  Scoped fetch that also populates the read-model annotations —
  `turn_count` and `last_active_at` — which `get_conversation/2` leaves at
  their defaults.

  Separate from `get_conversation/2` on purpose: that one is on the hot path
  of every prompt and interrupt, and does not need two extra joins to answer
  "does this conversation exist and is it yours".
  """
  def get_conversation_with_activity(id, user_id) when is_binary(user_id) do
    case Repo.one(from(c in annotated_query(user_id), where: c.id == ^id)) do
      nil -> nil
      conv -> Repo.preload(conv, [:sandbox, :agent, :vault])
    end
  end

  # The conversation list read-model: turn counts and last activity, both as
  # LEFT JOINed subqueries so the result stays a plain list of structs and no
  # caller N+1s.
  #
  # Only `kind: "output"` log events count toward `last_active_at` — stage
  # events (reconnects, sandbox lifecycle) would otherwise produce false
  # unread indicators.
  defp annotated_query(user_id) do
    turn_counts =
      from t in Turn,
        group_by: t.conversation_id,
        select: %{conversation_id: t.conversation_id, count: count(t.id)}

    last_log_at =
      from le in LogEvent,
        where: le.kind == "output",
        group_by: le.conversation_id,
        select: %{conversation_id: le.conversation_id, last_at: max(le.inserted_at)}

    from c in Conversation,
      as: :conv,
      where: c.user_id == ^user_id,
      left_join: tc in subquery(turn_counts),
      on: tc.conversation_id == c.id,
      left_join: ll in subquery(last_log_at),
      on: ll.conversation_id == c.id,
      select: %{
        c
        | turn_count: fragment("COALESCE(?, 0)", tc.count),
          last_active_at:
            fragment(
              "COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC')",
              ll.last_at,
              c.inserted_at
            )
      }
  end

  @doc """
  Whether a conversation has activity the owner has not seen.

  Unread until read at least once; read conversations go unread again when
  output arrives after the last read. Lived in three copies across the nav,
  the index and (implicitly) the API — one definition, so they cannot drift.
  """
  def unread?(%{last_read_at: nil, last_active_at: _}), do: true
  def unread?(%{last_read_at: _, last_active_at: nil}), do: false

  def unread?(%{last_read_at: read_at, last_active_at: active_at}),
    do: DateTime.compare(active_at, read_at) == :gt

  def unread?(_), do: false

  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conv, attrs) do
    conv
    |> Conversation.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_sidebar_update(updated.user_id)
      _ -> :ok
    end)
  end

  @doc """
  Best-effort terminate the running ConversationServer (destroys the sprite
  if alive), then delete the conversation row. Cascades to turns and log
  events via the FK.
  """
  def delete_conversation(%Conversation{id: id, user_id: user_id} = conv) do
    _ = Fountain.Conversations.ConversationServer.terminate(id)
    result = Repo.delete(conv)
    if match?({:ok, _}, result), do: broadcast_sidebar_update(user_id)
    result
  end

  @doc """
  Record that `user_id` has read `conversation_id` as of now.

  Scoped to owner — silently no-ops for a wrong user_id. Broadcasts a
  sidebar update so the unread dot clears in the nav without waiting for
  the next natural PubSub event.
  """
  def mark_read(conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update_all(
           from(c in Conversation,
             where: c.id == ^conversation_id and c.user_id == ^user_id
           ),
           set: [last_read_at: now]
         ) do
      {0, _} ->
        :ok

      {_, _} ->
        broadcast_sidebar_update(user_id)
        :ok
    end
  end

  # ── turns ─────────────────────────────────────────────────────────────────────────────

  def _unsafe_list_turns(conversation_id) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.turn_number],
        preload: [images: ^from(i in TurnImage, order_by: [asc: i.position])]
    )
  end

  @doc """
  Fetch a turn by conversation, scoped to the owning user.

  Joins through the conversation so a turn belonging to another tenant is
  indistinguishable from one that doesn't exist.
  """
  def get_turn_by_conversation(turn_id, conversation_id, user_id) when is_binary(user_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where:
          t.id == ^turn_id and t.conversation_id == ^conversation_id and
            c.user_id == ^user_id,
        select: t
    )
  end

  def _unsafe_insert_turn_images(_turn_id, []), do: {:ok, 0}

  @doc """
  Store a turn's images.

  Goes through `TurnImage.changeset/2` rather than `Repo.insert_all` against a
  raw table name. The old path skipped the schema entirely, so the media-type
  allowlist, the required fields and the `(turn_id, position)` unique constraint
  never ran — the schema described validation that nothing performed, and a
  client could store an arbitrary media type. Volume here is a handful of rows
  per turn, so there was never a bulk-insert win to protect.

  Returns `{:ok, count}` or `{:error, changeset}`. Both are handled by the
  caller; a rejected image must not take a turn down with it.
  """
  def _unsafe_insert_turn_images(turn_id, images) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    images
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {%{media_type: mt, data: data}, idx}, {:ok, count} ->
      changeset =
        TurnImage.changeset(%TurnImage{}, %{
          turn_id: turn_id,
          position: idx,
          media_type: mt,
          data: data,
          inserted_at: now
        })

      case Repo.insert(changeset) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end

  def _unsafe_get_turn_image(turn_id, position) do
    Repo.get_by(TurnImage, turn_id: turn_id, position: position)
  end

  def _unsafe_next_turn_number(conversation_id) do
    last =
      Repo.one(
        from t in Turn,
          where: t.conversation_id == ^conversation_id,
          select: max(t.turn_number)
      )

    (last || 0) + 1
  end

  def _unsafe_create_turn(attrs) do
    with {:ok, turn} <- %Turn{} |> Turn.changeset(attrs) |> Repo.insert() do
      record_turn_usage(turn)
      {:ok, turn}
    end
  end

  # Turns carry no user_id of their own, so resolve it through the conversation.
  # One narrow select per turn, and turns are prompt-frequency rather than
  # request-frequency, so this is not a hot path.
  defp record_turn_usage(%Turn{} = turn) do
    case Repo.one(from c in Conversation, where: c.id == ^turn.conversation_id, select: c.user_id) do
      nil ->
        :ok

      user_id ->
        Fountain.Billing.record_usage(user_id, "turn_started", turn.id, "turn", %{
          "conversation_id" => turn.conversation_id,
          "turn_number" => turn.turn_number
        })
    end
  end

  def _unsafe_update_turn(%Turn{} = turn, attrs) do
    turn
    |> Turn.changeset(attrs)
    |> Repo.update()
  end

  # ── log events ──────────────────────────────────────────────────────────────────────────

  @doc """
  Total persisted bytes of `kind: "output"` log data for a conversation.
  Without tenant scoping — the caller is the conversation's own server,
  seeding the durable-output budget (#331).
  """
  def _unsafe_output_byte_total(conversation_id) do
    Repo.one(
      from(l in LogEvent,
        where: l.conversation_id == ^conversation_id and l.kind == "output",
        select: coalesce(sum(fragment("octet_length(?)", l.data)), 0)
      )
    )
  end

  @doc """
  Insert a log event. Returns the inserted struct (with integer `:id`,
  used as the SSE event id).
  """
  def log!(attrs) do
    # Microsecond precision so the LiveView can compute stage durations
    # under 1s (provision steps run in tens of ms).
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now())

    # Redact here rather than at the call sites. Sprite output is persisted
    # verbatim and log_events has none of the encryption the secret itself has,
    # so a path that forgets to scrub writes plaintext credentials to a table
    # that outlives the conversation. Doing it at the single writer means a new
    # log path is covered whether or not its author knew to.
    attrs = redact_attrs(attrs)

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  defp redact_attrs(%{conversation_id: conv_id, data: data} = attrs)
       when is_binary(conv_id) and is_binary(data) do
    %{attrs | data: Fountain.Conversations.Redaction.redact(conv_id, data)}
  end

  defp redact_attrs(attrs), do: attrs

  @doc """
  Record a stage transition: persist the log event, broadcast it to the
  conversation's PubSub topic, and emit a `[:fountain, :stage]` telemetry
  event.

  Every operationally meaningful outcome flows through here — provision
  done/failed, reattach, turn done/failed — so the Prometheus stage counter
  (and the alert on it) cannot drift from what clients see on the stream.
  `stage` and `status` are the metric's only tags; both value sets are small
  and fixed. `conv_id` stays in metadata and must never become a tag.
  """
  def publish_stage(conv_id, stage, status, meta \\ %{}) do
    event =
      log!(%{
        conversation_id: conv_id,
        kind: "stage",
        stage: stage,
        state: status,
        data: Jason.encode!(meta)
      })

    Fountain.Telemetry.event(
      [:stage],
      %{stage: stage, status: status, conv_id: conv_id},
      %{count: 1}
    )

    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, event})

    event
  end

  @doc """
  List a conversation's log events after `after_id`, oldest first.

  Options:

    * `:streams` — allow-list of `"stdout"` / `"stderr"` / `"stage"`
    * `:limit` — cap the number of rows returned. A log feed is unbounded
      in principle (a chatty agent writes tens of thousands of rows), so
      the JSON read-model paginates rather than materialising all of it.
  """
  def _unsafe_list_log_events(conversation_id, after_id \\ 0, opts \\ []) do
    base =
      from e in LogEvent,
        where: e.conversation_id == ^conversation_id and e.id > ^after_id,
        order_by: [asc: e.id]

    base
    |> apply_streams_filter(Keyword.get(opts, :streams))
    |> apply_limit(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  defp apply_limit(query, nil), do: query

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0,
    do: from(e in query, limit: ^limit)

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
  def _unsafe_output_bytes_by_stream(conversation_id, turn_id) do
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

  # ── high-level lifecycle ──────────────────────────────────────────────────────────

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
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, parent_id} <- resolve_parent_id(attrs["parent_conversation_id"], user_id),
         :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_active(user_id),
         # Quota check + row insert under one per-user advisory lock: checked
         # separately they are check-then-insert, and N concurrent requests at
         # the cap could each pass and provision N-1 sprites over it (#330).
         {:ok, sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(user_id, fn ->
             create_sandbox(%{
               environment_id: agent.environment_id,
               sprite_name:
                 attrs["sprite_name"] || "fountain-#{tenant_prefix(user_id)}-#{short_id()}",
               status: "pending",
               user_id: user_id
             })
           end),
         {:ok, conv} <-
           create_conversation(%{
             sandbox_id: sandbox.id,
             agent_id: agent.id,
             vault_id: vault_id,
             user_id: user_id,
             runtime: agent.runtime,
             status: "pending",
             source: attrs["source"] || "api",
             parent_conversation_id: parent_id
           }) do
      # No prompt in the child spec — see start_conversation_server/4.
      start_result =
        Horde.DynamicSupervisor.start_child(
          Fountain.ConversationSupervisor,
          {ConversationServer,
           [
             conversation_id: conv.id,
             sandbox_id: sandbox.id,
             runtime_module: runtime_module
           ]}
        )

      case start_result do
        {:ok, pid} ->
          if is_binary(attrs["prompt"]) and attrs["prompt"] != "" do
            ConversationServer.queue_initial_prompt(
              pid,
              attrs["prompt"],
              attrs["images"] || []
            )
          end

          result = _unsafe_get_conversation!(conv.id)

          if result.parent_conversation_id do
            root_id = get_root_conversation_id(result.id)
            broadcast_graph_update(root_id)
          end

          broadcast_sidebar_update(user_id)
          {:ok, result}

        {:error, reason} ->
          # The conversation row was created successfully; mark it and its
          # sandbox failed so the status is visible on the conversation page,
          # then return it so callers (UI + API) navigate there rather than
          # leaving the user stuck on the new-conversation form.
          Logger.error(
            "ConversationServer failed to start for conv #{conv.id}: #{inspect(reason)}"
          )

          update_conversation(conv, %{status: "failed"})
          update_sandbox(sandbox, %{status: "failed"})
          result = _unsafe_get_conversation!(conv.id)
          broadcast_sidebar_update(user_id)
          {:ok, result}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # sobelow_skip ["SQL.Query"] — static SQL with a bound $1 UUID parameter.
  # sobelow_skip ["SQL.Query"] — static SQL with a bound $1 UUID parameter.
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

  defp broadcast_sidebar_update(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "sidebar:#{user_id}",
      {:sidebar_update, user_id}
    )
  end

  defp first_turn_query, do: from(t in Turn, where: t.turn_number == 1)

  defp short_id, do: Ecto.UUID.generate() |> binary_part(0, 8)

  defp tenant_prefix(user_id) when is_binary(user_id), do: binary_part(user_id, 0, 8)

  # `parent_conversation_id` arrives from a client-supplied header
  # (X-Fountain-Parent-Conversation-Id). The changeset only enforced an FK, so
  # any conversation id in the system was accepted — including another tenant's,
  # which grafted this conversation onto their spawn tree and theirs onto ours.
  #
  # A legitimate spawn comes from inside a sprite holding that tenant's own
  # token, so ownership always matches; a mismatch is a bug or an attack.
  defp resolve_parent_id(nil, _user_id), do: {:ok, nil}
  defp resolve_parent_id("", _user_id), do: {:ok, nil}

  defp resolve_parent_id(id, user_id) when is_binary(id) and is_binary(user_id) do
    case get_conversation(id, user_id) do
      nil -> {:error, :parent_not_found}
      conv -> {:ok, conv.id}
    end
  end

  defp resolve_vault_id(nil, _user_id, _agent), do: {:ok, nil}
  defp resolve_vault_id("", _user_id, _agent), do: {:ok, nil}

  defp resolve_vault_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_vault_allowed(id, agent) do
      case Fountain.Vaults.get_vault(id, user_id) do
        nil -> {:error, :vault_not_found}
        vault -> {:ok, vault.id}
      end
    end
  end

  # Vault values win on env-var collision, so an attached vault overrides
  # the agent's reviewed environment. agent.allowed_vault_ids scopes who
  # may do that: nil keeps the legacy any-tenant-vault behavior, [] forbids
  # attaching any vault, a non-empty list is an allowlist.
  defp check_vault_allowed(_vault_id, %Agents.Agent{allowed_vault_ids: nil}), do: :ok

  defp check_vault_allowed(vault_id, %Agents.Agent{allowed_vault_ids: allowed}) do
    if vault_id in allowed, do: :ok, else: {:error, :vault_not_allowed}
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
  (`terminated`, `failed`) — those don't auto-resume.
  """
  def wake_conversation(conv_id, initial_prompt \\ nil) do
    # Ownership: called from ConversationServer (which established ownership
    # before starting) and the boot-time rehydrator sweep. The agent fetched
    # below is the conversation's own agent_id, same tenant by construction.
    with %Conversation{} = conv <- _unsafe_get_conversation(conv_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         %Agents.Agent{} = agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:error, :no_agent},
         {:ok, runtime_module} <- Fountain.Runtimes.for_runtime(conv.runtime) do
      case maybe_reuse_sandbox(conv) do
        {:reuse, sandbox_id} ->
          # Reuse provisions nothing, so the fresh-path gates below never ran
          # here — a canceled or suspended user could restart a server against
          # a live sprite and keep prompting (#313). Same checks, minus the
          # quota (reusing adds no concurrency). The per-turn gate in
          # ConversationServer is the backstop; this one makes the refusal
          # synchronous at the API door.
          with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
               :ok <- Fountain.Billing.check_active(conv.user_id) do
            start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt)
          end

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
    case _unsafe_get_sandbox(sandbox_id) do
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

  # The child spec deliberately carries no prompt.
  #
  # Horde redistributes children when cluster membership changes — which every
  # deploy does — and restarts each one from its *stored child spec*. A prompt
  # baked into that spec is therefore replayed on every rebalance, silently
  # re-running the user's last message against the agent. Production
  # accumulated 38 turns from 2 distinct prompts on one conversation this way,
  # one duplicate per rollout, and the agent on the other end spent several
  # turns pointing out it was being asked the same thing repeatedly.
  #
  # So the prompt is delivered out of band, after the server exists. A cast is
  # queued behind handle_continue(:provision), so it is processed once
  # provisioning finishes; if provisioning fails the server stops and the cast
  # dies with it, which is the right outcome — no turn on a failed provision.
  defp start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
    with {:ok, pid} <-
           Horde.DynamicSupervisor.start_child(
             Fountain.ConversationSupervisor,
             {ConversationServer,
              [
                conversation_id: conv.id,
                sandbox_id: sandbox_id,
                runtime_module: runtime_module
              ]}
           ) do
      if is_binary(initial_prompt) and initial_prompt != "" do
        ConversationServer.queue_initial_prompt(pid, initial_prompt)
      end

      {:ok, _unsafe_get_conversation!(conv.id)}
    end
  end

  defp create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt) do
    # The sandbox being replaced is excluded: it is retired immediately below,
    # so counting it would block a wake that leaves concurrency unchanged.
    # Waking a dormant conversation provisions a fresh sprite, so it is subject
    # to the same gate as creating one. Without this, prompting an existing
    # conversation was an unmetered way past billing entirely.
    with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
         :ok <- Fountain.Billing.check_active(conv.user_id),
         # Same reservation as start_conversation/1 — see the note there (#330).
         {:ok, new_sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(conv.user_id, [exclude: conv.sandbox_id], fn ->
             create_sandbox(%{
               environment_id: agent.environment_id,
               sprite_name: "fountain-#{tenant_prefix(conv.user_id)}-#{short_id()}",
               status: "pending",
               user_id: conv.user_id
             })
           end),
         _ <- mark_old_sandbox_terminated(conv.sandbox_id),
         {:ok, conv} <-
           update_conversation(conv, %{sandbox_id: new_sandbox.id, status: "pending"}) do
      case start_conversation_server(conv, new_sandbox.id, runtime_module, initial_prompt) do
        {:ok, _} = ok ->
          ok

        {:error, {:already_started, winner_pid}} ->
          # Lost a concurrent wake of the same conversation. The winner's
          # server is running against its own sandbox; this one's just-created
          # row would otherwise sit pending — holding a quota slot — until the
          # reaper's pass an hour later, so a user at their cap could lock
          # themselves out by double-clicking (#330). Clean up our own row and
          # hand the prompt to the winner, which drops it if a turn is already
          # running — exactly right for a double-click.
          _ = mark_old_sandbox_terminated(new_sandbox.id)

          if is_binary(initial_prompt) and initial_prompt != "" do
            ConversationServer.queue_initial_prompt(winner_pid, initial_prompt)
          end

          {:ok, _unsafe_get_conversation!(conv.id)}

        {:error, _} = err ->
          err
      end
    end
  end

  defp assert_resumable(%Conversation{status: s}) when s in ~w(terminated failed) do
    {:error, :gone}
  end

  defp assert_resumable(_), do: :ok

  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    case _unsafe_get_sandbox(sandbox_id) do
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
