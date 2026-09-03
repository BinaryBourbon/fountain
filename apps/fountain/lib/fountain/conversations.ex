defmodule Fountain.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit
  alias Fountain.Conversations.{Blocks, Conversation, LogEvent, Sandbox, Turn, TurnImage}
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
      from s in admin_sandboxes(),
        order_by: [desc: s.inserted_at],
        left_join: u in User,
        on: u.id == s.user_id,
        preload: [user: u, conversations: []]
    )
  end

  @doc """
  How many sandboxes `_unsafe_list_sandboxes_admin/0` would return, without
  loading them or their owners.

  Deliberately built on the same query: the admin overview shows this count
  and links to the list, and a count that came from a second definition of
  "active" would disagree with the page it points at. `Quotas` has its own,
  narrower definition (`pending`/`starting`/`ready`) because a concurrency cap
  counts sandboxes being paid for, not sandboxes on screen.
  """
  def _unsafe_count_sandboxes_admin, do: Repo.aggregate(admin_sandboxes(), :count, :id)

  defp admin_sandboxes do
    from s in Sandbox, where: s.status not in ["terminated", "failed"]
  end

  def _unsafe_get_sandbox(id), do: Repo.get(Sandbox, id)
  def _unsafe_get_sandbox!(id), do: Repo.get!(Sandbox, id)

  @doc """
  Whether a conversation other than `conv_id` still holds `sandbox_id` — one
  that is not `terminated`/`failed`. A sandbox normally has one conversation;
  it gets a second when a teammate starts a fresh conversation on the same
  computer (`ConversationServer.release_conversation/2`, `Fountain.Team`),
  and from then on the retired thread's lifecycle must not reach the disk
  its successor is running on. `_unsafe_`: callers have established
  ownership of `conv_id` already (a GenServer, or a scoped fetch before it).
  """
  def _unsafe_sandbox_held_by_other?(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.exists?(
      from(c in Conversation,
        where:
          c.sandbox_id == ^sandbox_id and c.id != ^conv_id and
            c.status not in ["terminated", "failed"]
      )
    )
  end

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
  stopping a runaway agent means. A sandbox with no live server (including a
  `suspended` one) just has its row marked terminated: the conversation stays
  resumable (next prompt gets a fresh sandbox, with the agent's memory lost —
  decisions/0017) and the reaper destroys the sprite on its next pass, the
  same split `SandboxReaper.sweep_abandoned_sandboxes/0` uses.
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
          # A reclaimed sandbox took the tenant's conversations down with it,
          # which is worth a row each — this is the one termination they did
          # not ask for. #551 covers the reaper that calls this.
          Enum.each(
            live,
            &ConversationServer.terminate_conversation(&1.id, actor: "system:sandbox_reaper")
          )

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
    # Deliberately NOT Quotas.active_statuses(): `suspended` is excluded from
    # the concurrency cap (a parked sprite is not compute) but its sprite is
    # very much alive at sprites.dev, and a suspended tenant must not keep it.
    from(s in Sandbox,
      where: s.user_id == ^user_id and s.status in ~w(pending starting ready suspended),
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
  path in `ConversationServer.terminate_conversation/2`. Metering at this choke point means a
  new caller cannot forget to record usage, which is how `Billing.emit/5` ended
  up with no call sites at all despite being documented, schema'd and tested.
  """
  def update_sandbox(%Sandbox{} = sandbox, attrs) do
    was = sandbox.status

    changeset = sandbox |> Sandbox.changeset(attrs) |> stamp_terminated_at()

    with {:ok, updated} <- Repo.update(changeset) do
      record_sandbox_usage(was, updated)
      maybe_poke_sandbox_queue(was, updated)
      {:ok, updated}
    end
  end

  # A transition out of a cap-counting status can free both a tenant slot and
  # the deployment-wide fleet slot, so every tenant with active queue work
  # wants draining. This is the choke point every sandbox status change goes
  # through, and almost every one of them happens with an empty queue, so the
  # cost here is one existence probe and nothing else. When there is work, it
  # is one Oban insert and the job does the scan that finds the tenants —
  # never a scan plus an insert per waiting tenant on the caller's path.
  defp maybe_poke_sandbox_queue(was, %Sandbox{} = updated) do
    active = Fountain.Quotas.active_statuses()

    if was in active and updated.status not in active and
         Fountain.SandboxQueue.any_active_requests?() do
      Fountain.Workers.SandboxQueueDrainer.poke_all_later()
    end

    :ok
  rescue
    # Best-effort for the same reason `Billing.record_usage/5` rescues at this
    # choke point: the row is already committed, nearly every call site matches
    # `{:ok, _}` (ConversationServer's terminate path, `Accounts.Deletion`,
    # `SandboxReaper`), and a failed poke must not take down a caller that only
    # wanted to write a status. The five-minute cron backstop drains anyway.
    e ->
      Logger.warning("sandbox queue poke failed: #{Exception.message(e)}")
      :ok
  end

  @billable_terminal ~w(terminated failed)

  # `terminated_at` is when a sandbox stopped costing money, so spend
  # attribution reads it as the end of the billed interval
  # (`Fountain.Billing.SandboxUsage`). Stamping it here rather than at each
  # call site is the same choke-point argument as the metering below: of the
  # dozen writers of a terminal status, the ones that terminate passed a
  # timestamp and the ones that fail never did, which left every failed
  # sandbox looking like it was still running years later.
  #
  # Only fills a gap — a caller that passes its own `terminated_at` keeps it.
  defp stamp_terminated_at(changeset) do
    status = Ecto.Changeset.get_field(changeset, :status)

    if status in @billable_terminal and
         is_nil(Ecto.Changeset.get_field(changeset, :terminated_at)) do
      Ecto.Changeset.put_change(
        changeset,
        :terminated_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      changeset
    end
  end

  # Transitions only: update_sandbox/2 is called repeatedly with the same status
  # in places, and double-counting a sandbox would overstate a bill. Provision
  # transitions only — a `suspended → ready` wake reattaches to a sprite whose
  # provision was already recorded, so re-emitting would double-count it.
  defp record_sandbox_usage(was, %Sandbox{status: "ready"} = sandbox)
       when was in ["pending", "starting"] do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_provisioned",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name, "provider" => sandbox.provider}
    )
  end

  # `suspended → ready`: the wake side of a park/wake cycle (0017). No
  # sandbox_provisioned here — the provision was already recorded before the
  # sandbox parked (see above) — but the parked interval needs a start and an
  # end of its own so the duration roll-up can subtract it from
  # sandbox_terminated's duration_ms instead of billing parked time (#665).
  defp record_sandbox_usage("suspended", %Sandbox{status: "ready"} = sandbox) do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_resumed",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name, "provider" => sandbox.provider}
    )
  end

  # `ready → suspended`: the sandbox is parked, not destroyed, and stops
  # billing compute from here (0017). Paired with sandbox_resumed (or, for a
  # sandbox that never wakes again, with sandbox_terminated) so the duration
  # roll-up can tell parked time apart from run time (#665).
  defp record_sandbox_usage(was, %Sandbox{status: "suspended"} = sandbox)
       when was not in @billable_terminal do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_suspended",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name, "provider" => sandbox.provider}
    )
  end

  defp record_sandbox_usage(was, %Sandbox{status: status} = sandbox)
       when status in @billable_terminal and was not in @billable_terminal do
    # A sandbox that dies before reaching "ready" never emitted
    # sandbox_provisioned, but it is about to emit sandbox_terminated with a
    # duration — so the conversation count and the sandbox minutes on the
    # billing page would diverge for exactly the accounts where provisioning
    # is failing. Record the attempt under its own event type so the two
    # sides can be reconciled. `suspended` had to pass through `ready` to get
    # parked, so it is a completed provision, not a failed one.
    if was in ["pending", "starting"] do
      Fountain.Billing.record_usage(
        sandbox.user_id,
        "sandbox_provision_failed",
        sandbox.id,
        "sandbox",
        %{
          "sprite_name" => sandbox.sprite_name,
          "provider" => sandbox.provider,
          "status_before_failure" => was
        }
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
        "final_status" => status,
        "provider" => sandbox.provider
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
    |> Repo.preload([:agent, :agent_version, turns: first_turn_query()])
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

  `suspended` is deliberately excluded: a parked conversation has no server
  by design and wakes on the next prompt, not at boot — rehydrating every
  parked conversation would start a server (and re-arm an idle clock) for
  each one on every deploy.
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
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only.
  """
  def _unsafe_get_conversation!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @doc "Get conversation scoped to user. Returns nil on wrong owner or missing id."
  def get_conversation(id, user_id) when is_binary(user_id) do
    case Repo.get_by(Conversation, id: id, user_id: user_id) do
      nil -> nil
      conv -> Repo.preload(conv, [:sandbox, :agent, :vault, :agent_version])
    end
  end

  @doc "Get conversation scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_conversation!(id, user_id) when is_binary(user_id) do
    Conversation
    |> Repo.get_by!(id: id, user_id: user_id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @typedoc """
  A period's tokens, as the runtimes reported them. `cache_read` and
  `cache_write` are prompt-cache traffic; see `total_input/1`.
  """
  @type token_usage :: %{
          input: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          output: non_neg_integer()
        }

  @token_keys [:input, :cache_read, :cache_write, :output]

  # Only a JSON number is cast. `usage` is whatever the runtime reported and
  # nothing validates its shape on the way in, so one row with a string where
  # a number belongs would otherwise take the whole page down with it.
  defmacrop token_sum(usage, key) do
    quote do
      fragment(
        "CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::bigint ELSE 0 END",
        unquote(usage),
        unquote(key),
        unquote(usage),
        unquote(key)
      )
    end
  end

  @doc """
  What this tenant's agents spent, in tokens, over a period.

  Summed from `turns.usage` — the figure the runtime reported when the turn
  ended. Reading the turns rather than `conversations.usage_input_tokens` is
  what makes a period possible: those counters are lifetime totals, and a
  conversation started in March is still accruing in April.

  **All four keys, not two.** A coding agent re-reads its context every turn,
  so nearly everything it consumes arrives as `cache_read`: a month of real
  work on this instance was 1.5k `input` against 41M `cache_read`. Reporting
  `input` alone as "what went in" understates it by four orders of magnitude,
  which is worse than not reporting it at all. Callers get the breakdown and
  decide how to present it; `total_input/1` is the sum for the common case.

  Tokens are the tenant's own inference spend — Fountain runs on their key
  (ADR 0008) and never bills for them — so this is reported, not charged.
  Turns from before the usage column existed, and runtimes that report no
  usage, contribute nothing rather than a guess.
  """
  @spec token_usage(binary(), DateTime.t(), DateTime.t()) :: token_usage()
  def token_usage(user_id, %DateTime{} = from, %DateTime{} = to) when is_binary(user_id) do
    # The sum happens in Postgres: a busy month is tens of thousands of turns,
    # and this runs on a page load.
    #
    # `jsonb_typeof` before the cast, because `usage` is whatever the runtime
    # reported and nothing validates its shape on the way in. One row with a
    # string or an object where a number was expected would otherwise take
    # the whole page down with a cast error.
    query =
      from(t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.user_id == ^user_id and t.inserted_at >= ^from and t.inserted_at <= ^to,
        where: not is_nil(t.usage),
        select: %{
          input: sum(token_sum(t.usage, "input")),
          cache_read: sum(token_sum(t.usage, "cache_read")),
          cache_write: sum(token_sum(t.usage, "cache_write")),
          output: sum(token_sum(t.usage, "output"))
        }
      )

    case Repo.one(query) do
      %{} = row -> Map.new(@token_keys, &{&1, to_count(Map.get(row, &1))})
      _ -> empty_token_usage()
    end
  end

  @doc """
  Everything the model read: fresh input plus what it wrote to and read from
  the prompt cache. The cached reads dominate, and leaving them out is what
  made the first version of this metric wrong.
  """
  @spec total_input(token_usage()) :: non_neg_integer()
  def total_input(%{input: input, cache_read: read, cache_write: write}),
    do: input + read + write

  defp empty_token_usage, do: Map.new(@token_keys, &{&1, 0})

  # Postgres sums bigints as `numeric`, which arrives as a Decimal. The
  # callers of this want an integer they can format, and the spec says so.
  defp to_count(nil), do: 0
  defp to_count(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_count(n) when is_integer(n), do: n

  @doc """
  How many conversations this tenant has, and how many are live right now.

  Counted in the database. The console's dashboard wants two numbers, not the
  rows: loading a few hundred conversations with their agents and first turns
  to arrive at "3" is a page load nobody needs.
  """
  @spec conversation_counts(binary()) :: %{total: non_neg_integer(), active: non_neg_integer()}
  def conversation_counts(user_id) when is_binary(user_id) do
    query =
      from(c in Conversation,
        where: c.user_id == ^user_id,
        select: %{
          total: count(c.id),
          active: filter(count(c.id), c.status in ["pending", "running"])
        }
      )

    Repo.one(query) || %{total: 0, active: 0}
  end

  @doc """
  List conversations for user, ordered by most recently updated.

  Pass `roots_only: true` to exclude child conversations (those with a
  `parent_conversation_id`). Useful for hiding agent-spawned sub-conversations
  from the index when the user only wants to see top-level sessions.

  Further filters (#832), all combinable: `agent_id: id`, `channel_id:
  "fountain:team"` (the *bound* channel — a conversation unbound by
  `Fountain.Team.remove_teammate/3` no longer matches; a teammate's full
  history is `Team.list_teammate_conversations/2`), and `status: [..]` (a
  list of conversation statuses). Unpaged, like the list always was, except
  for `limit: n` — which the console's dashboard uses to ask for the five it
  shows instead of every row a busy account has.

  Populates the `last_active_at` virtual field using `kind: "output"` log
  events only — stage events (reconnects, lifecycle) are excluded so
  reconnects don't produce false unread indicators.
  """
  def list_conversations(user_id, opts \\ []) when is_binary(user_id) do
    roots_only = Keyword.get(opts, :roots_only, false)

    base = from(c in annotated_query(user_id), order_by: [desc: c.updated_at, desc: c.id])

    base =
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> limit(base, ^n)
        _ -> base
      end

    query =
      if roots_only do
        where(base, [conv: c], is_nil(c.parent_conversation_id))
      else
        base
      end

    query =
      Enum.reduce(opts, query, fn
        {:agent_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.agent_id == ^id)

        {:channel_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.channel_id == ^id)

        {:status, [_ | _] = statuses}, q ->
          where(q, [conv: c], c.status in ^statuses)

        _, q ->
          q
      end)

    Repo.all(query)
    |> Repo.preload([:agent, :agent_version, turns: first_turn_query()])
  end

  @doc """
  Every conversation of `user_id` bound to `channel_id`, live or not, newest
  activity first, with the read-model annotations (`turn_count`,
  `last_active_at`) populated and `:agent` + `:sandbox` preloaded.

  The channel-bound counterpart of `list_conversations/2`. Terminated and
  failed conversations are included on purpose: a binding outlives its
  sandbox (`start_or_resume_conversation/2` opens a new one next time), and
  the surface reading a channel — the team page — wants the last transcript
  even when nothing is running.
  """
  def list_channel_conversations(user_id, channel_id)
      when is_binary(user_id) and is_binary(channel_id) do
    from(c in annotated_query(user_id),
      where: c.channel_id == ^channel_id,
      order_by: [desc: c.inserted_at, desc: c.id]
    )
    |> Repo.all()
    |> Repo.preload([:agent, :sandbox])
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
      nil ->
        nil

      # The first turn rides along, as it does on the list: `first_prompt` in
      # the JSON is what a client titles an untitled conversation with.
      conv ->
        Repo.preload(conv, [:sandbox, :agent, :vault, :agent_version, turns: first_turn_query()])
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
    |> tap(fn
      # The account's first conversation is the request the verified landing
      # handed over (ADR 0038). Both create paths go through this write, so
      # the funnel's third step cannot be missed by a new door — and it does
      # not depend on the landing page still being open.
      {:ok, conv} -> Fountain.Activation.conversation_created(conv)
      _ -> :ok
    end)
  end

  @doc """
  Register the caller-defined tools of the bridge (#1202) on a conversation
  the caller already owns: the normalised list `Fountain.CallerTools`
  produced, last write wins. An unchanged list writes and records nothing —
  a framework loop re-sends the same list on every request.

  Ownership is the caller's job: `conv` must have come from a tenant-scoped
  fetch. Audited as `conversation.caller_tools_set` with the count and the
  names, never the schemas.
  """
  @spec set_caller_tools(Conversation.t(), [map()], keyword()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def set_caller_tools(%Conversation{} = conv, tools, opts \\ []) when is_list(tools) do
    if conv.caller_tools == tools do
      {:ok, conv}
    else
      conv
      |> Conversation.changeset(%{caller_tools: tools})
      |> Repo.update()
      |> tap(fn
        {:ok, updated} ->
          Audit.record(%{
            user_id: updated.user_id,
            action: "conversation.caller_tools_set",
            resource_type: "conversation",
            resource_id: updated.id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: %{
              "tool_count" => length(tools),
              "tool_names" => Enum.map(tools, & &1["name"])
            }
          })

        _ ->
          :ok
      end)
    end
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
  def delete_conversation(%Conversation{id: id, user_id: user_id} = conv, opts \\ []) do
    # `audit: false` on the cascade: this terminate is an implementation
    # detail of deleting, not a second thing the user asked for, and the
    # `conversation.deleted` below already accounts for the sandbox going
    # away. Without it every delete would read as terminate-then-delete.
    _ = Fountain.Conversations.ConversationServer.terminate_conversation(id, audit: false)
    result = Repo.delete(conv)

    if match?({:ok, _}, result) do
      broadcast_sidebar_update(user_id)

      Audit.record(%{
        user_id: user_id,
        action: "conversation.deleted",
        resource_type: "conversation",
        resource_id: id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{"title" => conv.title}
      })
    end

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

  # Advisory-lock namespace for per-sandbox machine operations. Distinct from
  # Quotas' per-user reservation (4315): this one is taken inside a turn
  # start, and the two must never be mistaken for one another.
  @sandbox_lock_namespace 4316

  @doc """
  Create a turn on a sandbox that may be shared, refusing when the runtime's
  capacity is used up by another conversation's running turn.

  `capacity` is `Managoat.Runtimes.ACP.concurrency/1`: `:unbounded` (claude,
  codex — several processes on one disk is the laptop shape) inserts exactly
  as `_unsafe_create_turn/1` does; an integer is checked and inserted under
  a per-sandbox advisory lock, so two conversations prompting the same
  opencode or gemini machine at the same moment cannot both win. Answers
  `{:error, :sandbox_at_capacity}` rather than queueing (ADR 0023 step 4).
  Usage is recorded after the transaction commits, never inside it.
  """
  def _unsafe_create_turn_on_sandbox(attrs, _sandbox_id, :unbounded),
    do: _unsafe_create_turn(attrs)

  def _unsafe_create_turn_on_sandbox(attrs, sandbox_id, capacity)
      when is_binary(sandbox_id) and is_integer(capacity) and capacity > 0 do
    conv_id = Map.fetch!(attrs, :conversation_id)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox_id)
        ])

        if _unsafe_running_turns_elsewhere(sandbox_id, conv_id) >= capacity do
          Repo.rollback(:sandbox_at_capacity)
        else
          case %Turn{} |> Turn.changeset(attrs) |> Repo.insert() do
            {:ok, turn} -> turn
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end)

    with {:ok, turn} <- result do
      record_turn_usage(turn)
      {:ok, turn}
    end
  end

  @doc """
  How many turns are running right now on `sandbox_id` for conversations
  other than `conv_id`. `_unsafe_`: the caller owns `conv_id`.
  """
  def _unsafe_running_turns_elsewhere(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id == ^sandbox_id and c.id != ^conv_id and t.status == "running",
        select: count(t.id)
    )
  end

  # No conversation to exclude: every running turn on the machine counts.
  def _unsafe_running_turns_elsewhere(sandbox_id, nil) when is_binary(sandbox_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id == ^sandbox_id and t.status == "running",
        select: count(t.id)
    )
  end

  @doc """
  Whether `sandbox_id` cannot take another turn from `conv_id` because other
  conversations already fill its runtime's capacity. Always false for
  `:unbounded`. An unlocked read for the API door; the locked check is
  `_unsafe_create_turn_on_sandbox/3`.
  """
  def _unsafe_sandbox_at_capacity?(_sandbox_id, _conv_id, :unbounded), do: false

  def _unsafe_sandbox_at_capacity?(sandbox_id, conv_id, capacity)
      when is_integer(capacity) and (is_binary(conv_id) or is_nil(conv_id)) do
    _unsafe_running_turns_elsewhere(sandbox_id, conv_id) >= capacity
  end

  @doc """
  Every conversation still holding `sandbox_id` — not `terminated` or
  `failed` — as ids: for a machine event that belongs on all of their
  transcripts, such as the checkpoint a park records.
  """
  def _unsafe_list_holder_ids(sandbox_id) when is_binary(sandbox_id) do
    Repo.all(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id and c.status not in ["terminated", "failed"],
        select: c.id
    )
  end

  @doc """
  The other conversations still holding `sandbox_id` — not `terminated` or
  `failed` — as ids: the machine's co-tenants, for a lifecycle decision one
  of them is about to make for all of them.
  """
  def _unsafe_list_cotenant_ids(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.all(
      from c in Conversation,
        where:
          c.sandbox_id == ^sandbox_id and c.id != ^conv_id and
            c.status not in ["terminated", "failed"],
        select: c.id
    )
  end

  @doc """
  Whether any *other* conversation on `sandbox_id` is mid-turn, or was active
  within the last `idle_seconds`.

  A server that finds its own conversation idle asks this before parking the
  machine everyone is on: the idle verdict is the machine's, taken over the
  union of its conversations' activity (ADR 0023 step 5), not one
  conversation's clock. Activity is a co-tenant's newest turn row (start or
  end), falling back to the conversation's own `updated_at` for one that
  never took a turn — the same fold `SandboxReaper.last_activity_at/1` makes
  for a sandbox with no server at all. `nil` idle seconds (the bound is off)
  is never busy.
  """
  def _unsafe_sandbox_busy_elsewhere?(
        sandbox_id,
        conv_id,
        idle_seconds,
        now \\ DateTime.utc_now()
      )

  def _unsafe_sandbox_busy_elsewhere?(_sandbox_id, _conv_id, nil, _now), do: false

  def _unsafe_sandbox_busy_elsewhere?(sandbox_id, conv_id, idle_seconds, now)
      when is_integer(idle_seconds) do
    cutoff = now |> DateTime.add(-idle_seconds, :second) |> DateTime.truncate(:second)

    case _unsafe_list_cotenant_ids(sandbox_id, conv_id) do
      [] ->
        false

      cotenants ->
        Repo.exists?(
          from t in Turn,
            where:
              t.conversation_id in ^cotenants and
                (t.status == "running" or t.inserted_at > ^cutoff or t.ended_at > ^cutoff)
        ) or
          Repo.exists?(
            from c in Conversation,
              left_join: t in Turn,
              on: t.conversation_id == c.id,
              where: c.id in ^cotenants and is_nil(t.id) and c.updated_at > ^cutoff
          )
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

  @doc """
  Update a turn's row. When the update ends the turn — its status becomes
  `completed`, `failed` or `interrupted` — the assistant's text for the
  turn is materialised into `reply_text` in the same write (#826): every
  turn ending goes through here, from the ConversationServer's six endings
  to the orphan sweep, so search coverage is by construction rather than
  by each ending remembering. A turn that already carries a `reply_text`
  keeps it.

  The same write is where activation is decided (ADR 0038): a turn that ends
  carrying a reply is handed to `Fountain.Activation.turn_replied/1`, which
  does nothing unless it is the account's *first*. Same choke-point argument,
  same best-effort contract — it cannot fail this update.
  """
  def _unsafe_update_turn(%Turn{} = turn, attrs) do
    changeset =
      turn
      |> Turn.changeset(attrs)
      |> maybe_put_reply_text(turn)

    result = Repo.update(changeset)

    # The write that *materialises* the reply, not every later update to a
    # turn that already has one — a turn is written again after it ends, and
    # activation happens once.
    with {:ok, updated} <- result,
         text when is_binary(text) <- Ecto.Changeset.get_change(changeset, :reply_text) do
      Fountain.Activation.turn_replied(updated)
    end

    result
  end

  @doc """
  Reconciles a turn left `running` after its server or runtime disappeared.

  The turn transition and the conversation's `running` to `idle` transition
  are conditional writes. If another process already ended the turn, this is
  a no-op rather than overwriting its result. `orphaned_at` records that the
  true end of work is unknown, which keeps the interval out of billing and
  usage attribution.

  This function is unscoped because it is called by a conversation's own
  server and by the system reaper. Callers may supply audit attribution.
  """
  def _unsafe_orphan_turn(%Turn{} = turn, why, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reply_text = turn.reply_text || _unsafe_turn_reply_text(turn)

    updates =
      [status: "interrupted", ended_at: now, orphaned_at: now]
      |> maybe_set_reply_text(reply_text)

    result =
      Repo.transaction(fn ->
        {count, _} =
          from(t in Turn, where: t.id == ^turn.id and t.status == "running")
          |> Repo.update_all(set: updates)

        if count == 0 do
          :noop
        else
          {conversation_count, _} =
            from(c in Conversation,
              where: c.id == ^turn.conversation_id and c.status == "running"
            )
            |> Repo.update_all(set: [status: "idle", updated_at: now])

          {
            Repo.get!(Turn, turn.id),
            Repo.get!(Conversation, turn.conversation_id),
            conversation_count == 1
          }
        end
      end)

    case result do
      {:ok, :noop} ->
        :noop

      {:ok, {updated_turn, conv, conversation_changed?}} ->
        if is_nil(turn.reply_text) and is_binary(updated_turn.reply_text) do
          Fountain.Activation.turn_replied(updated_turn)
        end

        if conversation_changed?, do: broadcast_sidebar_update(conv.user_id)

        publish_stage(turn.conversation_id, "reattach", "interrupted", %{
          outcome: "turn_orphaned",
          turn_id: turn.id,
          turn_number: turn.turn_number,
          reason: why
        })

        Audit.record(%{
          user_id: conv.user_id,
          action: "conversation.turn.orphaned",
          resource_type: "turn",
          resource_id: turn.id,
          actor: Keyword.get(opts, :actor, "system:conversation_server"),
          metadata: %{
            "conversation_id" => turn.conversation_id,
            "turn_number" => turn.turn_number,
            "reason" => why
          }
        })

        {:ok, updated_turn, conv}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_set_reply_text(updates, nil), do: updates

  defp maybe_set_reply_text(updates, reply_text),
    do: Keyword.put(updates, :reply_text, reply_text)

  @doc """
  Record a turn's end-of-turn token usage (#827): stamp `usage` on the turn
  and add its `input` / `output` to the conversation's running sums, in one
  transaction. `usage` is the normalised map `Managoat.ACP.Usage`
  produces (`%{"input" => n, "output" => n, ...}`); nil records nothing.

  Once per turn, by the ConversationServer when the `session/prompt`
  response arrives — never from the live `usage_update`s, whose meaning
  differs per runtime (a per-call delta, a thread total, a per-step figure).
  A second call for the same turn would double-count the conversation, so
  it refuses when the turn already carries a usage.
  """
  def _unsafe_record_turn_usage(%Turn{}, nil), do: :ok
  def _unsafe_record_turn_usage(%Turn{usage: %{}}, _usage), do: {:error, :already_recorded}

  def _unsafe_record_turn_usage(%Turn{} = turn, %{} = usage) do
    # `usage` is whatever the runtime reported. The map is stored as it came,
    # but the counters it increments are bigints: a string or an object here
    # used to raise inside the transaction and take the turn's usage
    # recording with it. Anything that is not a non-negative integer counts
    # as nothing, which is what an unreported figure already counts as.
    input = counter_value(Map.get(usage, "input"))
    output = counter_value(Map.get(usage, "output"))

    Repo.transaction(fn ->
      {:ok, updated} = turn |> Turn.changeset(%{usage: usage}) |> Repo.update()

      {1, _} =
        Repo.update_all(
          from(c in Conversation, where: c.id == ^turn.conversation_id),
          inc: [usage_input_tokens: input, usage_output_tokens: output]
        )

      updated
    end)
  end

  defp counter_value(n) when is_integer(n) and n >= 0, do: n
  defp counter_value(_), do: 0

  @terminal_turn_statuses ~w(completed failed interrupted)

  defp maybe_put_reply_text(%Ecto.Changeset{valid?: false} = changeset, _turn), do: changeset

  defp maybe_put_reply_text(changeset, %Turn{reply_text: nil} = turn) do
    case Ecto.Changeset.get_change(changeset, :status) do
      status when status in @terminal_turn_statuses ->
        Ecto.Changeset.put_change(changeset, :reply_text, _unsafe_turn_reply_text(turn))

      _ ->
        changeset
    end
  end

  defp maybe_put_reply_text(changeset, _turn), do: changeset

  @doc """
  Materialise `reply_text` on every ended turn that has none — the one-time
  backfill for turns that predate the column (`Fountain.Release.backfill_turn_replies/0`).
  Returns the number of turns written; a turn with no assistant text is
  left null and visited again next run (there are few, and re-parsing them
  is cheap). No tenant scope: a system sweep.
  """
  def _unsafe_backfill_reply_texts do
    from(t in Turn,
      where: t.status in ^@terminal_turn_statuses and is_nil(t.reply_text),
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
    |> Enum.reduce(0, fn turn, n ->
      case _unsafe_turn_reply_text(turn) do
        nil ->
          n

        text ->
          {:ok, _} = turn |> Turn.changeset(%{reply_text: text}) |> Repo.update()
          n + 1
      end
    end)
  end

  @doc """
  The assistant's text for `turn`, from its events through the same parse
  the transcript uses (`Blocks.assistant_text/2`); nil when there is none.
  Reads the conversation's runtime for the legacy dialects. Without tenant
  scope: the caller holds the turn.
  """
  def _unsafe_turn_reply_text(%Turn{} = turn) do
    runtime =
      Repo.one(from c in Conversation, where: c.id == ^turn.conversation_id, select: c.runtime)

    case turn.id |> _unsafe_list_turn_log_events() |> Blocks.assistant_text(runtime) do
      "" -> nil
      text -> text
    end
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

    # Webhook dispatch hangs off the same call for the same reason the stage
    # counter does (#700): a new lifecycle outcome cannot be added without
    # subscribers seeing it. Best-effort by construction — `dispatch_stage/1`
    # rescues everything, because a webhook that is not sent is a degraded
    # integration and a stage transition that raises is a stuck agent.
    Fountain.Webhooks.dispatch_stage(event)
    mirror_stage_to_analytics(event, meta)

    event
  end

  # Which stage outcomes are product events, and why only these.
  #
  # Provisioning already reaches PostHog through `Billing.record_usage/5`
  # (`usage.sandbox_provisioned` and friends), which carries the user id for
  # free — mirroring it here as well would double-count the same fact. What
  # metering does *not* have is how a turn ended, and "how many turns finished,
  # and how many of those failed" is the single most useful thing this system
  # can report about itself. The two failure stages join it because they are
  # the ones that end an activation attempt.
  @analytics_stages %{
    {"turn", "done"} => true,
    {"turn", "failed"} => true,
    {"turn", "interrupted"} => true,
    {"setup", "failed"} => true,
    {"model", "failed"} => true
  }

  defp mirror_stage_to_analytics(event, meta) do
    # `enabled?/0` first, before anything touches the database. This runs on
    # the conversation hot path, and an instance with no PostHog key must not
    # pay a query for a feature it has not turned on.
    with true <- Fountain.Analytics.enabled?(),
         true <- Map.has_key?(@analytics_stages, {event.stage, event.state}),
         user_id when is_binary(user_id) <- conversation_user_id(event.conversation_id) do
      Fountain.Analytics.capture(
        "conversation.#{event.stage}.#{event.state}",
        user_id,
        meta
        |> Fountain.Analytics.sanitize()
        |> Map.merge(%{
          "conversation_id" => event.conversation_id,
          "source" => "conversation"
        })
      )
    else
      _ -> :ok
    end
  rescue
    # Same contract as the webhook dispatch above it: a stage transition that
    # raises is a stuck agent, and analytics is never worth that.
    _ -> :ok
  end

  defp conversation_user_id(nil), do: nil

  defp conversation_user_id(conversation_id) do
    Repo.one(from c in Conversation, where: c.id == ^conversation_id, select: c.user_id)
  end

  @doc """
  One turn's log events, oldest first — the events a single reply is rendered
  from. Ownership rides on the turn: reach it through a tenant-scoped
  conversation first.
  """
  def _unsafe_list_turn_log_events(turn_id) when is_binary(turn_id) do
    Repo.all(from e in LogEvent, where: e.turn_id == ^turn_id, order_by: [asc: e.id])
  end

  @doc """
  The id of a conversation's newest log event, or `0` when it has none.

  A cursor for "everything from here on", which is what a caller about to
  prompt a live conversation needs: the events its own turn produces, without
  the ones a previous turn already wrote. Ownership rides on the conversation —
  reach it through a tenant-scoped fetch first.
  """
  @spec _unsafe_latest_log_event_id(String.t()) :: integer()
  def _unsafe_latest_log_event_id(conversation_id) when is_binary(conversation_id) do
    from(e in LogEvent,
      where: e.conversation_id == ^conversation_id,
      select: max(e.id)
    )
    |> Repo.one()
    |> Kernel.||(0)
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

  # `streams` is a list of allowed stream identifiers: any value of the
  # `stream` column, plus `"stage"`, the synthetic name for `kind: "stage"`
  # events (which have no `stream` value of their own). `nil`/empty list =
  # no filter.
  #
  # There is deliberately **no allow-list of stream names**. There used to be
  # one — `["stdout", "stderr"]`, written when those were the only two — and
  # when ACP added a third (`"acp"`, one stored `session/update` per line) the
  # filter silently answered "nothing" for it: an unrecognised name fell to a
  # `where: false`. A name we do not know is now simply a name no row has,
  # which returns nothing on its own without a list to keep in step.
  #
  # `event_in_streams?/2` is the same rule for an event already in hand. The
  # two must agree — see the test that runs one table through both. They did
  # not agree before, and the gap was invisible in exactly the way that hurts:
  # live events matched, replayed ones did not, so a filtered stream returned
  # a conversation's future and none of its past.
  defp apply_streams_filter(query, nil), do: query
  defp apply_streams_filter(query, []), do: query

  defp apply_streams_filter(query, streams) when is_list(streams) do
    real_streams = Enum.reject(streams, &(&1 == "stage"))
    include_stage? = "stage" in streams

    cond do
      include_stage? and real_streams != [] ->
        from e in query,
          where: e.kind == "stage" or e.stream in ^real_streams

      include_stage? ->
        from e in query, where: e.kind == "stage"

      true ->
        from e in query, where: e.stream in ^real_streams
    end
  end

  @doc """
  Whether one already-loaded event belongs to a `?streams=` selection.

  The in-memory half of `apply_streams_filter/2`, used for events arriving
  live over PubSub, where there is no query to add a `where` to. It lives here
  rather than in the controller so the two halves of one rule sit together and
  are tested together.
  """
  @spec event_in_streams?(LogEvent.t(), [String.t()] | nil) :: boolean()
  def event_in_streams?(_ev, nil), do: true
  def event_in_streams?(_ev, []), do: true
  def event_in_streams?(%LogEvent{kind: "stage"}, streams), do: "stage" in streams

  def event_in_streams?(%LogEvent{stream: s}, streams) when is_binary(s),
    do: s in streams

  def event_in_streams?(_ev, _streams), do: false

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

  @doc """
  The most recent persisted output lines of one stream for a turn, as a set.

  Feeds the ACP reattach path: sprites replays the tail of the session buffer
  (measured at 16 KiB), and the peer re-encodes protocol lines so a byte count
  cannot align the replay with what is already stored — content can. `limit`
  rows is comfortably more than 16 KiB of `session/update` lines.
  """
  def _unsafe_recent_output_lines(conversation_id, turn_id, stream, limit \\ 400) do
    from(e in LogEvent,
      where:
        e.conversation_id == ^conversation_id and e.turn_id == ^turn_id and
          e.kind == "output" and e.stream == ^stream,
      order_by: [desc: e.id],
      limit: ^limit,
      select: e.data
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── high-level lifecycle ──────────────────────────────────────────────────────────

  alias Fountain.Agents
  alias Fountain.Conversations.ConversationServer

  @doc """
  Like `start_conversation/2`, but a conversation already bound to
  `attrs["channel_id"]` is resumed instead of a new one being opened.

  The channel key is opaque and client-supplied — a Buzz channel id from ACP
  `session/new` `_meta.channelId` (#774). A client that forgets its sessions
  (a restarted `buzz-acp`) then lands back on the same conversation, and so
  the same sandbox and workspace, rather than opening a fresh one per restart.

  Resumes the **latest live** conversation for the same user + agent + vault
  + environment override + channel — `terminated` and `failed` ones are past
  resuming, so a new one is opened and becomes the binding. So is one whose
  *sandbox* is `terminated` or `failed` (#779): the machine is gone, and the
  workspace with it, so the channel gets a new conversation on a working one
  rather than a continuous-looking transcript on a blank disk. A `suspended`
  sandbox is parked, not gone, and still resumes. Returns `{:ok, conv,
  :resumed}` or `{:ok, conv, :created}`; without a `channel_id` it always
  creates.

  `attrs["fresh"]` (`true`) skips the resume this once: the conversation
  currently bound to the channel is unbound (its `channel_id` cleared — it
  keeps running, and the sandbox reaper retires it like any other idle one)
  and a new one is opened as the binding. It is how a chat harness relays its
  owner's `!rotate` — ACP `session/new` `_meta.freshSession` — through a
  binding that would otherwise hand the old conversation straight back.
  Unbinding, rather than relying on "newest wins", keeps the outcome
  independent of `inserted_at`'s one-second precision.

  Two concurrent first calls for one channel can both create; the next call
  resumes whichever is newer. Nothing is audited on the resume path — nothing
  changed.
  """
  def start_or_resume_conversation(attrs, opts \\ [])

  def start_or_resume_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs,
        opts
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent) do
      case find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id) do
        %Conversation{} = conv ->
          if fresh_requested?(attrs) do
            with {:ok, _} <- unbind_channel(conv),
                 {:ok, fresh} <- start_conversation(attrs, opts),
                 do: {:ok, fresh, :created}
          else
            {:ok, conv, :resumed}
          end

        nil ->
          with {:ok, conv} <- start_conversation(attrs, opts), do: {:ok, conv, :created}
      end
    end
  end

  def start_or_resume_conversation(attrs, opts) do
    with {:ok, conv} <- start_conversation(attrs, opts), do: {:ok, conv, :created}
  end

  # `true` or `"true"` — the ACP adapter sends a JSON boolean, a hand-built
  # request may send a string. Anything else is not a request.
  defp fresh_requested?(%{"fresh" => fresh}), do: fresh in [true, "true"]
  defp fresh_requested?(_attrs), do: false

  # The rotated-away conversation stops being the channel's binding. Nothing
  # else about it changes: if it is mid-turn it finishes, and it stays in the
  # user's list under its own id.
  defp unbind_channel(%Conversation{} = conv) do
    conv
    |> Ecto.Changeset.change(channel_id: nil)
    |> Repo.update()
  end

  # The newest conversation still worth resuming for this binding. `vault_id`
  # is part of the key: two entries on one agent with different vaults are
  # different identities (#727) and must not share a conversation. So is the
  # environment override (#783): an identity that switches environments must
  # not resume a conversation provisioned from the old one.
  #
  # The sandbox is part of it too (#779): the 24 hour ceiling destroys a
  # sandbox while its conversation stays `idle`, and resuming that row wakes
  # onto a *fresh* machine with the workspace gone (#778 makes the turn work;
  # #936 is the memory it loses) inside a transcript that reads as continuous.
  # A channel is better served by a new conversation on a working machine, so
  # the binding follows the machine, not just the conversation row.
  # `suspended` is not in the list: that sandbox is parked, not gone, and its
  # disk wakes back up with the workspace on it.
  @doc """
  The conversation a channel binding resumes, resolved exactly as
  `start_or_resume_conversation/2` resolves it (same vault/environment key),
  without opening one when there is none. For a request that must land on an
  existing conversation or fail — a tool answer on the bridge (#1202) — where
  opening a sandbox for a thread that has no parked call would be the wrong
  side effect. Tenant-scoped through `attrs["user_id"]`.
  """
  @spec channel_conversation(map()) :: Conversation.t() | nil
  def channel_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent) do
      find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id)
    else
      _ -> nil
    end
  end

  def channel_conversation(_attrs), do: nil

  defp find_channel_conversation(user_id, agent_id, vault_id, env_id, channel_id) do
    from(c in Conversation,
      join: s in assoc(c, :sandbox),
      where:
        c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^channel_id and
          c.status not in ["terminated", "failed"] and
          s.status not in ["terminated", "failed"],
      order_by: [desc: c.inserted_at],
      limit: 1
    )
    |> where_vault(vault_id)
    |> where_environment(env_id)
    |> Repo.one()
  end

  defp where_vault(query, nil), do: from(c in query, where: is_nil(c.vault_id))
  defp where_vault(query, vault_id), do: from(c in query, where: c.vault_id == ^vault_id)

  defp where_environment(query, nil), do: from(c in query, where: is_nil(c.environment_id))
  defp where_environment(query, id), do: from(c in query, where: c.environment_id == ^id)

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`              — agent to run
    - `prompt`                — optional first prompt (sends turn 1 immediately)
    - `sprite_name`           — optional override; defaults to "fountain-<short-user-id>-<short-id>"
    - `vault_id`              — optional vault whose secrets override the env's
    - `environment_id`        — optional environment to provision from instead of the
                                agent's own (#783); subject to `agent.allowed_environment_ids`
    - `permission_policy`     — optional per-tool permission override (#939); may only
                                narrow the agent's own policy, never widen it
    - `source`                — optional; one of "ui", "api", "agent" (default "api")
    - `parent_conversation_id` — optional; UUID of the conversation that spawned this one
    - `title`                 — optional display title (the team page names a teammate with it)
  """
  def start_conversation(attrs, opts \\ [])

  # `sandbox_id`: attach to a machine the caller already has instead of
  # provisioning one (ADR 0023 gate 3). Everything about the launch is
  # resolved the same way; only the sandbox step differs.
  def start_conversation(%{"sandbox_id" => sandbox_id} = attrs, opts)
      when is_binary(sandbox_id) and sandbox_id != "" do
    attach_conversation(sandbox_id, attrs, opts)
  end

  def start_conversation(%{"agent_id" => agent_id, "user_id" => user_id} = attrs, opts)
      when is_binary(user_id) do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, runtime_module} <- Managoat.Runtimes.for_runtime(agent.runtime),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, mode} <- resolve_sandbox_mode(attrs["sandbox_mode"], agent),
         {:ok, perm_policy} <- resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, parent_id} <- resolve_parent_id(attrs["parent_conversation_id"], user_id),
         :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_spend(user_id),
         # Whose inference key would run this (#1388): refused only when it
         # would be Fountain's and the deployment has spent its day. A door
         # with no platform key configured runs no query here.
         :ok <- Fountain.PlatformInference.gate(user_id, agent.model),
         # A persistent launch lands on the identity's home when there is one
         # (ADR 0023 gate 6): `{:home, sandbox}` leaves the `with` and attaches
         # below. Only when there is none does a machine get provisioned, and
         # it is stamped as the home.
         :new <- home_or_new(mode, user_id, agent, env_id || agent.environment_id, vault_id),
         {:ok, provider} <- resolve_sandbox_provider(agent),
         {:ok, sprite_name} <- mint_sprite_name(provider, user_id, attrs["sprite_name"]),
         # Quota check + row insert under one per-user advisory lock: checked
         # separately they are check-then-insert, and N concurrent requests at
         # the cap could each pass and provision N-1 sprites over it (#330).
         {:ok, sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(user_id, fn ->
             create_sandbox(%{
               environment_id: env_id || agent.environment_id,
               # The identity the disk is built from (ADR 0023); an attach
               # later must name the same three.
               agent_id: agent.id,
               vault_id: vault_id,
               mode: mode,
               sprite_name: sprite_name,
               status: "pending",
               provider: Atom.to_string(provider),
               user_id: user_id
             })
           end),
         {:ok, conv} <-
           create_conversation(%{
             sandbox_id: sandbox.id,
             agent_id: agent.id,
             # Ownership: agent came from the scoped get_agent above.
             agent_version_id: Agents._unsafe_current_version_id(agent.id),
             vault_id: vault_id,
             environment_id: env_id,
             user_id: user_id,
             runtime: agent.runtime,
             status: "pending",
             source: attrs["source"] || "api",
             parent_conversation_id: parent_id,
             channel_id: attrs["channel_id"],
             title: attrs["title"],
             permission_policy: perm_policy,
             caller_tools: attrs["caller_tools"] || []
           }) do
      # Recorded here rather than in either branch below: both of them return
      # {:ok, conv}. The row exists and the sandbox reservation is spent even
      # when the server fails to start, so "a conversation was created" is
      # true either way, and a trail that only logged the happy path would
      # under-report exactly the runs someone is trying to explain.
      #
      # The prompt is described, never quoted — see `send_prompt/4`.
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent.id,
          "agent_name" => agent.name,
          "source" => conv.source,
          "with_prompt" => is_binary(attrs["prompt"]) and attrs["prompt"] != "",
          "parent_conversation_id" => parent_id
        }
      })

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
      nil ->
        {:error, :not_found}

      # The identity already has a home: this launch is a conversation on it.
      {:home, %Sandbox{} = home} ->
        attach_conversation(home.id, attrs, opts)

      # Two persistent launches of one identity raced to create its home and
      # this one lost at the unique index. The winner's row is the home now;
      # land on it rather than fail a request that asked for nothing unusual.
      {:error, %Ecto.Changeset{errors: errors}} = err ->
        if Keyword.has_key?(errors, :home) do
          with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
               {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
               {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent),
               %Sandbox{} = home <-
                 _unsafe_find_home(user_id, agent.id, env_id || agent.environment_id, vault_id) do
            attach_conversation(home.id, attrs, opts)
          else
            _ -> err
          end
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  # The launch's sandbox mode: the agent's default unless the launch names
  # one (ADR 0023). Not an allowlisted override like `environment_id` — the
  # mode is not a security boundary; the tenant scope on the sandbox is.
  defp resolve_sandbox_mode(mode, %Agents.Agent{sandbox_mode: default}) when mode in [nil, ""],
    do: {:ok, default || "ephemeral"}

  defp resolve_sandbox_mode(mode, _agent) when is_binary(mode) do
    if mode in Sandbox.modes(), do: {:ok, mode}, else: {:error, :invalid_sandbox_mode}
  end

  defp resolve_sandbox_mode(_mode, _agent), do: {:error, :invalid_sandbox_mode}

  # `:new` when a machine has to be provisioned; `{:home, sandbox}` when the
  # identity already has one to land on. A home still provisioning from its
  # first launch cannot take a second conversation yet — its prompt would be
  # handed to the wrong server — so it reads as `:provisioning`, the same
  # retry-shortly answer a mid-provision conversation gives.
  defp home_or_new("ephemeral", _user_id, _agent, _env_id, _vault_id), do: :new

  defp home_or_new("persistent", user_id, %Agents.Agent{id: agent_id}, env_id, vault_id) do
    case _unsafe_find_home(user_id, agent_id, env_id, vault_id) do
      nil -> :new
      %Sandbox{status: s} when s in ["pending", "starting"] -> {:error, :provisioning}
      %Sandbox{} = home -> {:home, home}
    end
  end

  @doc """
  The live home of an agent identity — the one persistent sandbox for
  `(user, agent, environment, vault)` that is not terminated or failed — or
  nil. `nil` environment and vault are part of the identity, not wildcards.
  `_unsafe_`: callers have resolved the agent tenant-scoped already.
  """
  def _unsafe_find_home(user_id, agent_id, env_id, vault_id)
      when is_binary(user_id) and is_binary(agent_id) do
    from(s in Sandbox,
      where:
        s.user_id == ^user_id and s.agent_id == ^agent_id and s.mode == "persistent" and
          s.status not in ["terminated", "failed"],
      order_by: [desc: s.inserted_at],
      limit: 1
    )
    |> where_sandbox_environment(env_id)
    |> where_sandbox_vault(vault_id)
    |> Repo.one()
  end

  defp where_sandbox_vault(query, nil), do: from(s in query, where: is_nil(s.vault_id))
  defp where_sandbox_vault(query, id), do: from(s in query, where: s.vault_id == ^id)

  defp where_sandbox_environment(query, nil),
    do: from(s in query, where: is_nil(s.environment_id))

  defp where_sandbox_environment(query, id), do: from(s in query, where: s.environment_id == ^id)

  @doc """
  Whether terminating `conv_id` leaves its sandbox standing: a home is never
  torn down by one conversation ending (ADR 0023 step 5), and neither is a
  machine another live conversation still holds. Both `ConversationServer`
  terminate paths ask this. `_unsafe_`: the caller owns `conv_id`.
  """
  def _unsafe_sandbox_kept_on_terminate?(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    case _unsafe_get_sandbox(sandbox_id) do
      %Sandbox{mode: "persistent"} -> true
      _ -> _unsafe_sandbox_held_by_other?(sandbox_id, conv_id)
    end
  end

  @doc """
  Every live home built on `environment_id`, across the agents that name it.
  `_unsafe_`: the caller owns the environment, and a home carries the same
  `user_id` as the environment its identity names.
  """
  def _unsafe_homes_for_environment(environment_id) when is_binary(environment_id) do
    live_homes(from(s in Sandbox, where: s.environment_id == ^environment_id))
  end

  @doc """
  Every live home built on `vault_id`. Same ownership note as
  `_unsafe_homes_for_environment/1`.
  """
  def _unsafe_homes_for_vault(vault_id) when is_binary(vault_id) do
    live_homes(from(s in Sandbox, where: s.vault_id == ^vault_id))
  end

  @doc """
  The homes of `agent_id` that moving it to `env_id` orphans: built for a
  different environment, so the next launch looks under the new identity key,
  finds nothing and provisions a fresh machine while these stay `ready` —
  holding a concurrency slot and a disk with the old environment's secrets on
  it (#1084). `nil` is an environment like any other here: an agent that
  loses its environment orphans the homes that had one.
  """
  def _unsafe_homes_orphaned_by_environment(agent_id, env_id) when is_binary(agent_id) do
    from(s in Sandbox, where: s.agent_id == ^agent_id)
    |> where_environment_differs(env_id)
    |> live_homes()
  end

  defp where_environment_differs(query, nil),
    do: from(s in query, where: not is_nil(s.environment_id))

  # `!=` is null-returning in SQL, so a home with no environment has to be
  # named explicitly or it reads as "not different" and survives.
  defp where_environment_differs(query, env_id),
    do: from(s in query, where: is_nil(s.environment_id) or s.environment_id != ^env_id)

  defp live_homes(query) do
    from(s in query,
      where: s.mode == "persistent" and s.status not in ["terminated", "failed"],
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Whether any of `homes` is running a turn — asked *before* a change that
  would pull the machine out from under a working agent, so the refusal costs
  nothing (#1084). Advisory only: each retirement re-checks under the
  per-sandbox advisory lock, which is what actually makes a teardown safe.
  """
  def _unsafe_any_home_mid_turn?(homes) when is_list(homes) do
    Enum.any?(homes, &(_unsafe_running_turns_elsewhere(&1.id, nil) > 0))
  end

  @doc """
  Retire `homes` whose identity moved out from under them — the agent's
  environment changed, or the environment or vault the key names was deleted
  (#1084). Each goes through `reset_sandbox/2`, so the conversations on it are
  kept and their next prompt builds a machine on the identity that exists now.

  Best-effort per home, and deliberately so: a turn that starts between the
  caller's check and this call leaves that one machine standing rather than
  cutting the turn. The orphan is then what it was before this existed — a
  `ready` row `fountain sandbox reset` clears — and the warning says which.
  Returns the number retired.
  """
  def _unsafe_retire_orphaned_homes(homes, reason, opts \\ []) when is_list(homes) do
    Enum.count(homes, fn home ->
      case reset_sandbox(home, Keyword.put(opts, :reason, reason)) do
        {:ok, _} ->
          true

        {:error, err} ->
          Logger.warning(
            "home #{home.id} orphaned by #{reason} was left standing: #{inspect(err)}"
          )

          false
      end
    end)
  end

  @doc """
  Tear down every home of `agent_id` — what deleting the agent does, since
  the identity the homes were built for is gone (ADR 0023 step 5). Each live
  conversation on a home is terminated (a home survives that on its own), then
  the sprite is destroyed and the row terminated. Best-effort per machine; a
  provider error is logged and the row still retires, so the reaper's sweep
  sees a terminal row rather than a live one nobody can find. Returns the
  number of homes torn down. `_unsafe_`: the caller owns the agent.
  """
  def _unsafe_destroy_homes_for_agent(agent_id) when is_binary(agent_id) do
    from(s in Sandbox,
      where:
        s.agent_id == ^agent_id and s.mode == "persistent" and
          s.status not in ["terminated", "failed"]
    )
    |> Repo.all()
    |> Enum.map(&_unsafe_destroy_home/1)
    |> length()
  end

  @doc false
  def _unsafe_destroy_home(%Sandbox{} = sandbox) do
    sandbox = Repo.preload(sandbox, :conversations)

    sandbox.conversations
    |> Enum.reject(&(&1.status in ["terminated", "failed"]))
    |> Enum.each(&ConversationServer.terminate_conversation(&1.id, actor: "system:home_reset"))

    _unsafe_retire_home(sandbox)
  end

  # Destroy the sprite behind a home and retire its row. Best-effort on the
  # provider side: a destroy error is logged and the row still goes
  # `terminated`, so the reaper's sweep sees a terminal row rather than a
  # live one nobody can find. What happens to the conversations on the home
  # is the caller's decision — agent delete terminates them, a reset keeps
  # them.
  defp _unsafe_retire_home(%Sandbox{} = sandbox) do
    handle = Managoat.Sandbox.build_handle(sandbox_provider_atom(sandbox), sandbox.sprite_name)

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("home #{sandbox.sprite_name} destroy failed: #{inspect(reason)}")
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = update_sandbox(sandbox, %{status: "terminated", terminated_at: now})
    :ok
  end

  @doc """
  Reset a home: destroy the agent's machine so the next launch on its
  identity builds a clean one (ADR 0023 step 5, #1071). The conversations on
  it stay — idle and resumable — because the disk was the problem, not the
  transcripts; each is told the machine is gone, so its next prompt takes the
  wake path, which provisions a fresh home and moves the others onto it.

  `sandbox` came from the caller's scoped `get_sandbox/2`. Only a live
  `persistent` sandbox resets: an ephemeral one is a conversation's own and
  ends with it (`{:sandbox_not_resettable, "ephemeral"}`), a terminated or
  failed one is already gone (`{:sandbox_not_resettable, status}`). Refused
  with `:sandbox_mid_turn` while any conversation on it runs a turn — the
  check and the row flip share the per-sandbox advisory lock that turn
  creation takes, so a turn cannot slip in between them.

  `opts[:reason]` says *why*, and reaches every transcript on the machine and
  the audit row: `"home_reset"` (the owner asked — the default),
  `"environment_changed"`, `"environment_deleted"` or `"vault_deleted"` when
  the identity moved out from under the home (#1084).

  See `create_agent/2` for the rest of `opts` (`:actor`, `:request_ip`).
  """
  def reset_sandbox(%Sandbox{} = sandbox, opts \\ []) do
    cond do
      sandbox.mode != "persistent" ->
        {:error, {:sandbox_not_resettable, "ephemeral"}}

      sandbox.status in ["terminated", "failed"] ->
        {:error, {:sandbox_not_resettable, sandbox.status}}

      true ->
        do_reset_sandbox(sandbox, opts)
    end
  end

  defp do_reset_sandbox(%Sandbox{id: sandbox_id} = sandbox, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox_id)
        ])

        if _unsafe_running_turns_elsewhere(sandbox_id, nil) > 0 do
          Repo.rollback(:sandbox_mid_turn)
        else
          ids =
            Repo.all(
              from c in Conversation,
                where: c.sandbox_id == ^sandbox_id and c.status not in ["terminated", "failed"],
                select: c.id
            )

          # A fresh disk has no session to resume (#778).
          Repo.update_all(from(c in Conversation, where: c.id in ^ids),
            set: [runtime_session_id: nil, updated_at: now]
          )

          ids
        end
      end)

    with {:ok, ids} <- result do
      reason = Keyword.get(opts, :reason, "home_reset")
      message = reset_message(reason)

      # A conversation with a live server is told through it — the server
      # cuts nothing (no turn is running), records the event on its own
      # transcript and stops. One without a server gets the event recorded
      # here, so every transcript on the home says the same thing.
      Enum.each(ids, fn id ->
        case ConversationServer.whereis(id) do
          nil ->
            publish_stage(id, "sandbox", "done", %{
              event: "reset",
              reason: reason,
              by: "owner",
              message: message
            })

          pid ->
            GenServer.cast(pid, {:machine_gone, "reset", reason, message})
        end
      end)

      _unsafe_retire_home(sandbox)

      Audit.record(%{
        user_id: sandbox.user_id,
        action: "sandbox.reset",
        resource_type: "sandbox",
        resource_id: sandbox.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => sandbox.agent_id,
          "provider" => sandbox.provider,
          "conversations" => length(ids),
          "reason" => reason
        }
      })

      {:ok, _unsafe_get_sandbox!(sandbox.id)}
    end
  end

  # What each transcript on a reset home is told. The tail is the same every
  # time — the transcript survives, the next prompt builds a machine — because
  # that is the part a reader needs; the head says whose decision it was.
  @reset_tail "The transcript is kept; the next prompt builds a fresh machine, " <>
                "and the agent starts a new session there."

  defp reset_message("environment_changed"),
    do:
      "The agent moved to a different environment, so this machine is no longer its " <>
        @reset_tail

  defp reset_message("environment_deleted"),
    do: "The environment this machine was built for was deleted. " <> @reset_tail

  defp reset_message("vault_deleted"),
    do: "The vault this machine was built for was deleted. " <> @reset_tail

  defp reset_message(_owner), do: "The sandbox was reset by its owner. " <> @reset_tail

  # A conversation on a machine the caller already has (ADR 0023 gate 3).
  #
  # The launch is resolved exactly as a fresh one — agent, vault, environment,
  # permission policy, parent, the account and billing gates — and then the
  # sandbox is fetched tenant-scoped and checked instead of created: it must
  # be `ready` or `suspended`, it must have been built for the same agent,
  # environment and vault, and the runtime that shaped its disk must be the
  # agent's runtime still. No quota reservation: nothing new is provisioned,
  # and waking a `suspended` machine goes through the quota gate on the first
  # prompt as every wake does. The conversation is opened `idle` with no
  # server; a prompt supplied here is delivered through the ordinary wake
  # path, so a `ready` machine reattaches and a `suspended` one resumes, and
  # if that delivery is refused the row is removed again so a refused request
  # creates nothing.
  defp attach_conversation(
         sandbox_id,
         %{"agent_id" => agent_id, "user_id" => user_id} = attrs,
         opts
       )
       when is_binary(user_id) do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, _runtime_module} <- Managoat.Runtimes.for_runtime(agent.runtime),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, perm_policy} <- resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, parent_id} <- resolve_parent_id(attrs["parent_conversation_id"], user_id),
         :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_spend(user_id),
         # Whose inference key would run this (#1388): refused only when it
         # would be Fountain's and the deployment has spent its day. A door
         # with no platform key configured runs no query here.
         :ok <- Fountain.PlatformInference.gate(user_id, agent.model),
         %Sandbox{} = sandbox <- get_sandbox(sandbox_id, user_id) || {:error, :sandbox_not_found},
         :ok <- check_attachable(sandbox, agent, vault_id, env_id),
         :ok <- check_attach_capacity(sandbox, agent, attrs["prompt"]),
         {:ok, conv} <-
           create_conversation(%{
             sandbox_id: sandbox.id,
             agent_id: agent.id,
             # Ownership: agent came from the scoped get_agent above.
             agent_version_id: Agents._unsafe_current_version_id(agent.id),
             vault_id: vault_id,
             environment_id: env_id,
             user_id: user_id,
             runtime: agent.runtime,
             status: "idle",
             source: attrs["source"] || "api",
             parent_conversation_id: parent_id,
             channel_id: attrs["channel_id"],
             title: attrs["title"],
             permission_policy: perm_policy,
             # The bridge's tools (#1202) ride on both create paths: this
             # one is what a home sandbox's second conversation takes.
             caller_tools: attrs["caller_tools"] || []
           }) do
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent.id,
          "agent_name" => agent.name,
          "source" => conv.source,
          "with_prompt" => is_binary(attrs["prompt"]) and attrs["prompt"] != "",
          "parent_conversation_id" => parent_id,
          "sandbox_attached" => sandbox.id
        }
      })

      broadcast_sidebar_update(user_id)
      deliver_attach_prompt(conv, attrs, opts)
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp deliver_attach_prompt(conv, attrs, opts) do
    prompt = attrs["prompt"]

    if is_binary(prompt) and prompt != "" do
      case ConversationServer.send_prompt(conv.id, prompt, attrs["images"] || [], opts) do
        :ok ->
          {:ok, _unsafe_get_conversation!(conv.id)}

        {:error, _} = err ->
          # Nothing ran. Take the row back so a refused request created
          # nothing, exactly like a refused fresh launch.
          _ = Repo.delete(conv)
          broadcast_sidebar_update(conv.user_id)
          err
      end
    else
      {:ok, _unsafe_get_conversation!(conv.id)}
    end
  end

  defp check_attachable(%Sandbox{status: status}, _agent, _vault_id, _env_id)
       when status not in ["ready", "suspended"],
       do: {:error, {:sandbox_not_attachable, status}}

  defp check_attachable(%Sandbox{} = sandbox, %Agents.Agent{} = agent, vault_id, env_id) do
    cond do
      sandbox.agent_id != agent.id ->
        {:error, :sandbox_identity_mismatch}

      sandbox.vault_id != vault_id ->
        {:error, :sandbox_identity_mismatch}

      sandbox.environment_id != (env_id || agent.environment_id) ->
        {:error, :sandbox_identity_mismatch}

      # The disk was shaped by the runtime that first ran on it; an agent
      # whose runtime changed since gets a new machine, not this one.
      _unsafe_sandbox_runtime(sandbox.id) not in [nil, agent.runtime] ->
        {:error, :sandbox_runtime_mismatch}

      true ->
        :ok
    end
  end

  # With a prompt, the attach is a turn start too, so the capacity rule of
  # step 4 applies at the door; without one, the later prompt is gated by
  # `ConversationServer` as any prompt is.
  defp check_attach_capacity(%Sandbox{} = sandbox, %Agents.Agent{runtime: runtime}, prompt)
       when is_binary(prompt) and prompt != "" do
    capacity = Managoat.Runtimes.ACP.concurrency(runtime)

    if _unsafe_sandbox_at_capacity?(sandbox.id, nil, capacity),
      do: {:error, :sandbox_at_capacity},
      else: :ok
  end

  defp check_attach_capacity(_sandbox, _agent, _prompt), do: :ok

  @doc "The runtime of the newest conversation on `sandbox_id`, or nil when it has none."
  def _unsafe_sandbox_runtime(sandbox_id) when is_binary(sandbox_id) do
    Repo.one(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 1,
        select: c.runtime
    )
  end

  @doc "One of the caller's sandboxes, or nil. A foreign or malformed id reads as nil."
  def get_sandbox(id, user_id) when is_binary(id) and is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> Repo.get_by(Sandbox, id: id, user_id: user_id)
      :error -> nil
    end
  end

  @doc """
  The caller's sandboxes, newest first, each with its conversations (newest
  first). `status: [...]` filters; anything else lists every status, the
  terminated ones included — a machine's history is part of the account.
  """
  def list_sandboxes(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from(s in Sandbox,
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at, desc: s.id]
      )

    query =
      case Keyword.get(opts, :status) do
        [_ | _] = statuses -> where(query, [s], s.status in ^statuses)
        _ -> query
      end

    query
    |> Repo.all()
    |> Repo.preload(conversations: from(c in Conversation, order_by: [desc: c.inserted_at]))
  end

  @doc "`get_sandbox/2` with the conversations preloaded, newest first."
  def get_sandbox_with_conversations(id, user_id) when is_binary(id) and is_binary(user_id) do
    case get_sandbox(id, user_id) do
      nil ->
        nil

      s ->
        Repo.preload(s, conversations: from(c in Conversation, order_by: [desc: c.inserted_at]))
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

  # The sandbox name is minted here and stamped on the row; the adapter is
  # handed nothing else (ADR 0018), which is why the runner provider's names
  # carry the runner they live on (ADR 0022) — minting one is a placement
  # decision, made now, and fails plainly when the user has no runner online.
  # A caller-supplied name (test seams) is honored as before.
  defp mint_sprite_name(:runner, user_id, nil), do: Fountain.Runners.mint_sandbox_name(user_id)
  defp mint_sprite_name(_provider, _user_id, name) when is_binary(name), do: {:ok, name}

  defp mint_sprite_name(_provider, user_id, nil),
    do: {:ok, "fountain-#{tenant_prefix(user_id)}-#{short_id()}"}

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

  # A per-launch environment override (#783): the conversation is provisioned
  # from this environment instead of the agent's own, and stays pinned to it
  # across wakes. Resolved exactly like the vault — a scoped fetch (a foreign
  # id reads as not found, so it cannot be probed) behind the agent's allowlist.
  defp resolve_environment_id(nil, _user_id, _agent), do: {:ok, nil}
  defp resolve_environment_id("", _user_id, _agent), do: {:ok, nil}

  defp resolve_environment_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_environment_allowed(id, agent) do
      case Fountain.Environments.get_environment(id, user_id) do
        nil -> {:error, :environment_not_found}
        env -> {:ok, env.id}
      end
    end
  end

  # An override replaces the reviewed environment wholesale, so it is scoped
  # the same way as a vault: nil = any tenant environment, [] = none, a
  # non-empty list is an allowlist. Default nil is deliberate — a caller who
  # can attach a vault can already override every key, so a stricter default
  # here would guard nothing (#783). Naming the agent's own environment is not
  # an override, so it passes regardless of the list.
  defp check_environment_allowed(_id, %Agents.Agent{allowed_environment_ids: nil}), do: :ok
  defp check_environment_allowed(id, %Agents.Agent{environment_id: id}), do: :ok

  defp check_environment_allowed(id, %Agents.Agent{allowed_environment_ids: allowed}) do
    if id in allowed, do: :ok, else: {:error, :environment_not_allowed}
  end

  @doc """
  Answer a permission request a running agent is blocked on (#940).

  Tenant-scoped: the conversation is fetched for `user_id` first, so a request
  id from another tenant reads as not found rather than as a permission error.

  **A sprite may not answer its own prompt.** It holds a `FOUNTAIN_TOKEN` and
  could otherwise approve the very tool it just asked for, which would make the
  policy decorative. The loop is closed by name here rather than left to the
  actor vocabulary to imply.

  Audited as a decision about tenant-owned state, per 0013: the tool and the
  verdict, never the tool's input.
  """
  @spec answer_permission_request(binary(), binary(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def answer_permission_request(conv_id, user_id, request_id, option_id, opts \\ [])
      when is_binary(conv_id) and is_binary(user_id) do
    actor = Keyword.get(opts, :actor, "self")

    cond do
      actor == "sprite" ->
        {:error, :sprite_may_not_answer}

      is_nil(get_conversation(conv_id, user_id)) ->
        {:error, :not_found}

      true ->
        do_answer_permission(conv_id, user_id, request_id, option_id, opts)
    end
  end

  defp do_answer_permission(conv_id, user_id, request_id, option_id, opts) do
    case ConversationServer.answer_permission(conv_id, request_id, option_id) do
      :ok ->
        Audit.record(%{
          user_id: user_id,
          action: "conversation.permission_answered",
          resource_type: "conversation",
          resource_id: conv_id,
          actor: Keyword.get(opts, :actor, "self"),
          request_ip: Keyword.get(opts, :request_ip),
          metadata: %{"request_id" => request_id, "option_id" => option_id}
        })

        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Record that the permission policy withheld a tool from a running agent.

  Called by the `ConversationServer` when its peer reports a refusal (#939).
  The actor is `sprite`: the agent asked, the policy answered, and no human was
  involved — attributing it to the person who happened to write the policy
  would be a lie about who was at the keyboard.

  Only refusals are recorded. A turn makes dozens of tool calls and a row per
  allow would make the trail a second copy of the transcript, which 0013
  forbids for exactly this reason. The tool's *input* is never recorded, only
  its name and the verdict.
  """
  @spec record_permission_denied(binary(), String.t() | nil, String.t()) :: :ok
  def record_permission_denied(conversation_id, tool, verdict) when is_binary(conversation_id) do
    case _unsafe_get_conversation(conversation_id) do
      nil ->
        :ok

      conv ->
        Audit.record(%{
          user_id: conv.user_id,
          action: "conversation.permission_denied",
          resource_type: "conversation",
          resource_id: conv.id,
          actor: "sprite",
          metadata: %{"tool" => tool, "verdict" => verdict}
        })

        :ok
    end
  end

  # A per-launch permission override (#939). Unlike the vault and environment
  # overrides, this one needs no allowlist on the agent: `check_narrows/2`
  # refuses anything looser than the agent's own policy, so a launch cannot
  # reach a permission the agent did not already grant. There is nothing to
  # allow-list because there is nothing to escalate to.
  #
  # Rejected loudly rather than clamped. `Permissions.effective/2` clamps
  # anyway — that is the invariant the peer relies on — but a caller who asked
  # to loosen a policy and silently got a tighter one would have no way to
  # tell, and the difference matters when the ask was a mistake.
  defp resolve_permission_policy(nil, _agent), do: {:ok, nil}
  defp resolve_permission_policy(policy, _agent) when policy == %{}, do: {:ok, nil}

  defp resolve_permission_policy(policy, agent) when is_map(policy) do
    with :ok <- validate_policy_shape(policy),
         :ok <- check_runtime_asks(policy, agent),
         :ok <- Managoat.ACP.Permissions.check_narrows(agent.permission_policy, policy) do
      {:ok, policy}
    end
  end

  defp resolve_permission_policy(_policy, _agent), do: {:error, :permission_policy_invalid}

  # A launch cannot be protected by a policy the runtime never consults. Refused
  # rather than accepted-and-ignored — see `ACP.asks_permission?/1`, measured.
  defp check_runtime_asks(policy, agent) do
    if not Managoat.ACP.Permissions.needs_enforcement?(policy) or
         Managoat.Runtimes.ACP.asks_permission?(agent.runtime) do
      :ok
    else
      {:error, {:permission_policy_unenforceable, agent.runtime}}
    end
  end

  defp validate_policy_shape(policy) do
    Enum.find_value(policy, :ok, fn {tool, verdict} ->
      cond do
        not is_binary(tool) or tool == "" ->
          {:error, :permission_policy_invalid}

        verdict not in Managoat.ACP.Permissions.verdicts() ->
          {:error, :permission_policy_invalid}

        not Managoat.ACP.Permissions.buildable?(verdict) ->
          {:error, {:permission_policy_unbuilt, verdict}}

        true ->
          nil
      end
    end)
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
     terminated, and start the server pointing at the new sandbox. The
     runtime session does not follow — it lived on the old disk — so the
     server clears `runtime_session_id` once the fresh sprite is up and the
     next turn starts a new one (#778). The Fountain conversation, its
     transcript and its title carry over; the agent's in-context memory
     does not.

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
         {:ok, runtime_module} <- Managoat.Runtimes.for_runtime(conv.runtime) do
      case maybe_reuse_sandbox(conv) do
        {:reuse, sandbox_id} ->
          # Reuse provisions nothing, so the fresh-path gates below never ran
          # here — a canceled or suspended user could restart a server against
          # a live sprite and keep prompting (#313). Same checks. Reusing a
          # `ready` sandbox adds no concurrency, so no quota; waking a
          # `suspended` one re-adds compute, so wake_suspended_sandbox re-runs
          # the quota gate. The per-turn gate in ConversationServer is the
          # backstop; this one makes the refusal synchronous at the API door.
          with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
               :ok <- Fountain.Billing.check_spend(conv.user_id),
               # Whose inference key would run this (#1388): refused only when it
               # would be Fountain's and the deployment has spent its day. A door
               # with no platform key configured runs no query here.
               :ok <- Fountain.PlatformInference.gate(conv.user_id, agent.model),
               {:ok, _} <- wake_suspended_sandbox(conv.user_id, sandbox_id) do
            case start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
              {:error, {:already_started, winner_pid}} ->
                # Lost a concurrent wake of the same conversation to another
                # caller reusing the same sandbox. Mirrors the handoff in
                # create_fresh_sandbox_and_start/4 (#330), but reuse provisions
                # no row of its own, so there is nothing here to clean up —
                # just hand the prompt to the winner, which drops it if a turn
                # is already running.
                if is_binary(initial_prompt) and initial_prompt != "" do
                  ConversationServer.queue_initial_prompt(winner_pid, initial_prompt)
                end

                {:ok, _unsafe_get_conversation!(conv.id)}

              other ->
                other
            end
          end

        {:provisioning, sandbox_id} ->
          # The row says a server is (or was) provisioning this sandbox. The
          # registry may simply not have caught up with a server started on
          # another node — `session/new` and the first prompt arrive ~30 ms
          # apart and can land on different pods — so wait for it before
          # concluding it is dead. If it turns up, hand it the prompt exactly
          # as the `already_started` branches do; if it does not, the
          # provision died with its BEAM and a fresh one is right (#800).
          case ConversationServer.await_registered(conv.id) do
            {:ok, pid} ->
              Logger.info(
                "conv #{conv.id}: server for pending sandbox #{sandbox_id} " <>
                  "appeared during the registry settle window; handing off the prompt"
              )

              if is_binary(initial_prompt) and initial_prompt != "" do
                ConversationServer.queue_initial_prompt(pid, initial_prompt)
              end

              {:ok, _unsafe_get_conversation!(conv.id)}

            :timeout ->
              create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)
          end

        :create_new ->
          create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)

        {:error, _} = err ->
          err
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # Probe the existing sandbox: if it's `ready` or `suspended` and sprites.dev
  # confirms the sprite still exists, we can reattach without provisioning a
  # new one. Otherwise, fall through to creating a fresh sandbox.
  defp maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  defp maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case _unsafe_get_sandbox(sandbox_id) do
      %{status: status, sprite_name: name} = sandbox
      when status in ["ready", "suspended"] and is_binary(name) ->
        probe_reusable_sandbox(sandbox, sandbox_id)

      # A provision is in flight — or was, in a BEAM that is gone. The
      # caller waits for the registry before deciding which (#800).
      %{status: status} when status in ["pending", "starting"] ->
        {:provisioning, sandbox_id}

      _ ->
        :create_new
    end
  end

  # The row's provider is sticky: a parked sandbox wakes on the backend that
  # holds its disk, never on whatever the instance default is by now. A row
  # whose (non-default) provider lost its credentials fails retryably — the
  # same protect-the-parked-disk reasoning as :sprite_probe_failed below;
  # falling through to :create_new would retire the row and orphan (or lose)
  # the parked sandbox. Re-adding the credentials restores wakes.
  defp probe_reusable_sandbox(%{status: status, sprite_name: name} = sandbox, sandbox_id) do
    provider = sandbox_provider_atom(sandbox)

    if provider != Fountain.SandboxProviders.default_provider() and
         not Fountain.SandboxProviders.enabled?(provider) do
      Logger.warning(
        "sandbox #{sandbox_id} is on disabled provider #{provider}; refusing to wake or retire"
      )

      {:error, {:sandbox_provider_disabled, provider}}
    else
      probe_sandbox(provider, name, status, sandbox_id)
    end
  end

  defp probe_sandbox(provider, name, status, sandbox_id) do
    case Managoat.Sandbox.get(Managoat.Sandbox.build_handle(provider, name)) do
      {:ok, _info} ->
        {:reuse, sandbox_id}

      {:error, :not_found} ->
        :create_new

      # The machine behind a runner-backed sandbox is not connected (#834):
      # the same protect-the-disk rule as below, named, so the caller can say
      # "the machine is off" rather than "the provider is unreachable".
      {:error, {:unavailable, :runner_offline}} ->
        {:error, :runner_offline}

      {:error, reason} ->
        # A transient probe failure must not cost the disk: falling to
        # :create_new retires this row, and the reaper then destroys the
        # still-live sprite — with the agent's memory on it. Only a
        # definitive not-found gives up the sandbox; anything else fails the
        # wake retryably (503 + Retry-After at the API).
        #
        # This clause was `suspended`-only until #799: a `ready` row is the
        # same parked disk once its server is gone (a deploy, a crash, a
        # partition), and the 2026-08-18 incident showed the provider going
        # unreachable for 70 s with nine `ready` rows behind it.
        Logger.warning(
          "sprite probe failed for #{status} sandbox #{sandbox_id}: #{inspect(reason)}"
        )

        {:error, :sprite_probe_failed}
    end
  end

  def sandbox_provider_atom(%{provider: provider}) when is_binary(provider),
    do: String.to_existing_atom(provider)

  def sandbox_provider_atom(_sandbox), do: :sprites

  # Placement for a NEW sandbox: the agent's override, else the instance
  # default. Only an override is gated on enabledness — the default keeps its
  # lazy credential check (a credential-less boot fails at provision time
  # with the missing variable named, exactly as before), while an agent
  # pinned to a provider whose credentials were since removed fails here
  # with an error the API/UI can explain.
  defp resolve_sandbox_provider(%Agents.Agent{sandbox_provider: nil}),
    do: {:ok, Fountain.SandboxProviders.default_provider()}

  defp resolve_sandbox_provider(%Agents.Agent{sandbox_provider: value}) do
    provider = String.to_existing_atom(value)

    if Fountain.SandboxProviders.enabled?(provider) do
      {:ok, provider}
    else
      {:error, {:sandbox_provider_disabled, provider}}
    end
  end

  # Waking a suspended sandbox turns a parked sprite back into compute, so it
  # re-runs the quota gate — under the same advisory lock as creation, with the
  # row re-read inside. Two concurrent wakes both probe `suspended`; the loser
  # re-reads the winner's `ready` flip and must not double-stamp the clock.
  # `exclude: sandbox_id` makes the check identical for both ("does the user
  # have capacity besides this sandbox"), so the loser is never spuriously
  # refused at the cap for a wake that added no concurrency.
  defp wake_suspended_sandbox(user_id, sandbox_id) do
    case _unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: "suspended"} ->
        Fountain.Quotas.with_sandbox_reservation(user_id, [exclude: sandbox_id], fn ->
          case _unsafe_get_sandbox(sandbox_id) do
            %Sandbox{status: "suspended"} = sandbox ->
              resume_and_wake(sandbox)

            sandbox ->
              {:ok, sandbox}
          end
        end)

      sandbox ->
        {:ok, sandbox}
    end
  end

  # Resume BEFORE the row flips: if the provider's wake call fails, the row
  # stays `suspended` and the wake fails retryably — the parked disk is the
  # agent's memory, and a row marked ready over a still-parked backend would
  # strand it. For Sprites resume is a probe (waking is a side effect of the
  # next exec); for pause/stop providers it is the call that restarts the
  # sandbox.
  defp resume_and_wake(sandbox) do
    handle =
      Managoat.Sandbox.build_handle(sandbox_provider_atom(sandbox), sandbox.sprite_name)

    case Managoat.Sandbox.resume(handle) do
      {:ok, _handle} ->
        update_sandbox(sandbox, %{
          status: "ready",
          last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:error, reason} ->
        Logger.warning(
          "resume failed for suspended sandbox #{sandbox.id} (#{inspect(reason)}); " <>
            "leaving it parked"
        )

        {:error, :sandbox_resume_failed}
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
    # The replacement keeps the mode of the machine it replaces: a home whose
    # sprite is gone is re-provisioned as the home, and every conversation on
    # it follows (move_cotenants/3). The old row is retired *first* for a
    # home — the partial unique index allows one live home per identity, and
    # the probe has already said this sprite is gone (ADR 0023 gate 6).
    old = if conv.sandbox_id, do: _unsafe_get_sandbox(conv.sandbox_id)
    mode = (old && old.mode) || "ephemeral"
    if mode == "persistent", do: _ = mark_old_sandbox_terminated(conv.sandbox_id)

    with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
         :ok <- Fountain.Billing.check_spend(conv.user_id),
         # Whose inference key would run this (#1388): refused only when it
         # would be Fountain's and the deployment has spent its day. A door
         # with no platform key configured runs no query here.
         :ok <- Fountain.PlatformInference.gate(conv.user_id, agent.model),
         # A fresh sandbox is a fresh placement decision — re-resolve from
         # the agent, so a conversation whose old sandbox died can migrate
         # providers naturally.
         {:ok, provider} <- resolve_sandbox_provider(agent),
         {:ok, sprite_name} <- mint_sprite_name(provider, conv.user_id, nil),
         # Same reservation as start_conversation/1 — see the note there (#330).
         {:ok, new_sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(
             conv.user_id,
             [exclude: conv.sandbox_id],
             fn ->
               create_sandbox(%{
                 environment_id: conv.environment_id || agent.environment_id,
                 agent_id: conv.agent_id,
                 vault_id: conv.vault_id,
                 mode: mode,
                 sprite_name: sprite_name,
                 status: "pending",
                 provider: Atom.to_string(provider),
                 user_id: conv.user_id
               })
             end
           ) do
      # The row is repointed *after* the server starts, not before (#717).
      #
      # The old order repointed first, so a wake that then lost the start race
      # left the conversation pointing at the sandbox it had just terminated,
      # while the winner ran on a different one — a conversation that reads as
      # terminated in the API and the UI while it is happily serving turns, and
      # an orphan `ready` row nothing references. `fountain acp` reproduced it
      # on every session, because `session/new` and the first prompt arrive a
      # second apart and the prompt takes this path before the registry has the
      # new server.
      #
      # Deferring leaves a much smaller window — between the server starting
      # and the row being updated — in which the row still names the old
      # sandbox. That one is transient and self-correcting; the old one was
      # permanent.
      #
      # #800 closed the other half: a prompt that finds a `pending` row now
      # waits for the registry (`ConversationServer.await_registered/2`)
      # before coming here, so the first server — often on another pod, and
      # so invisible to this node's registry for a beat — is found and
      # handed the prompt instead of being raced by a second provision.
      case start_conversation_server(conv, new_sandbox.id, runtime_module, initial_prompt) do
        {:ok, _} ->
          old_sandbox_id = conv.sandbox_id
          _ = mark_old_sandbox_terminated(old_sandbox_id)

          {:ok, conv} =
            update_conversation(conv, %{sandbox_id: new_sandbox.id, status: "pending"})

          # The machine was gone for everyone on it, not just the conversation
          # that noticed (ADR 0023 gate 5).
          move_cotenants(old_sandbox_id, new_sandbox.id, conv.id)

          {:ok, _unsafe_get_conversation!(conv.id)}

        {:error, {:already_started, winner_pid}} ->
          # Lost a concurrent wake of the same conversation. The winner's
          # server is running against its own sandbox; this one's just-created
          # row would otherwise sit pending — holding a quota slot — until the
          # reaper's pass an hour later, so a user at their cap could lock
          # themselves out by double-clicking (#330). Clean up our own row and
          # hand the prompt to the winner, which drops it if a turn is already
          # running — exactly right for a double-click.
          #
          # The conversation is left alone: the winner owns it, and it is the
          # winner's sandbox the row should name.
          _ = mark_old_sandbox_terminated(new_sandbox.id)

          if is_binary(initial_prompt) and initial_prompt != "" do
            ConversationServer.queue_initial_prompt(winner_pid, initial_prompt)
          end

          {:ok, _unsafe_get_conversation!(conv.id)}

        {:error, _} = err ->
          # Nothing ever ran on this sandbox. Retiring it keeps a failed wake
          # from holding a quota slot until the reaper's next pass — the same
          # reasoning as the branch above.
          _ = mark_old_sandbox_terminated(new_sandbox.id)
          err
      end
    end
  end

  defp assert_resumable(%Conversation{status: s}) when s in ~w(terminated failed) do
    {:error, :gone}
  end

  defp assert_resumable(_), do: :ok

  # A wake that found the sprite gone re-provisioned a machine for the
  # conversation that woke. Every other live conversation on the old row was
  # on the same dead disk, so it follows onto the new one (ADR 0023 gate 5) —
  # the alternative leaves each co-tenant pointing at a `terminated` row and
  # provisioning yet another machine on its own next prompt, and the shared
  # disk they were sharing ends up as N disks.
  #
  # `old_sandbox_id` is the row the waking conversation *used* to name; by the
  # time this runs the waking conversation itself already names the new one,
  # so it is not among the co-tenants.
  #
  # A co-tenant whose server is somehow alive holds a handle to the dead
  # sprite; it is told the machine is gone, cuts any turn, and stops, so its
  # next prompt takes the wake path onto the new row. `runtime_session_id` is
  # cleared for each: a fresh disk has no session to resume (#778).
  defp move_cotenants(nil, _new_sandbox_id, _conv_id), do: :ok

  defp move_cotenants(old_sandbox_id, new_sandbox_id, conv_id)
       when is_binary(old_sandbox_id) and is_binary(new_sandbox_id) do
    case _unsafe_list_cotenant_ids(old_sandbox_id, conv_id) do
      [] ->
        :ok

      ids ->
        message =
          "The sandbox this conversation was on is gone; it moved to a fresh one together " <>
            "with the conversations that shared it. The transcript is kept, but the agent " <>
            "starts a new session and will not remember the earlier turns."

        Enum.each(ids, fn id ->
          case ConversationServer.whereis(id) do
            nil -> :ok
            pid -> GenServer.cast(pid, {:machine_gone, "replaced", "sprite_gone", message})
          end
        end)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.update_all(from(c in Conversation, where: c.id in ^ids),
          set: [sandbox_id: new_sandbox_id, runtime_session_id: nil, updated_at: now]
        )

        Enum.each(ids, fn id ->
          publish_stage(id, "sandbox", "done", %{
            event: "replaced",
            reason: "sprite_gone",
            sandbox_id: new_sandbox_id,
            message: message
          })
        end)

        :ok
    end
  end

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
