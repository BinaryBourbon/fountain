defmodule Fountain.Conversations.ExecutionGuard do
  @moduledoc """
  Durable arbitration between a bounded turn finishing and its deadline expiring.

  Conversation then journal row locks serialize registration, completion, and
  termination claims. Provider I/O is deliberately outside these transactions:
  `claim_termination` persists an attempt before handing a worker permission for
  exactly one write. A lost reply leaves a fence; it never grants another write.

  These unscoped operations are for an already-owned conversation server or the
  system deadline worker. Registration derives ownership from persisted parents;
  callers cannot supply a tenant, sandbox name, or provider. A provider-issued
  session identity must be bound by the trusted command transport, never stdout.

  This module is a journal primitive. API admission, transport binding, deadline
  scheduling and lifecycle integration must use it before enforcement is shipped.
  """
  import Ecto.Query

  alias Fountain.{Audit, Repo}
  alias Fountain.Conversations.{Conversation, ExecutionLimits, Sandbox, Turn, TurnExecution}
  alias Fountain.Conversations.{DeadlineEvents, LogEvent}

  @fenced ~w(awaiting_identity ready submitted uncertain)
  @terminal_turns ~w(completed failed interrupted)

  def _unsafe_register(turn_id, connection_id, %DateTime{} = deadline_at, opts \\ []) do
    transaction(fn ->
      turn = Repo.get(Turn, turn_id) || Repo.rollback(:not_found)
      observed = Repo.get(Conversation, turn.conversation_id) || Repo.rollback(:not_found)
      lock_sandbox(observed.sandbox_id)
      conv = lock_parent(turn.conversation_id) || Repo.rollback(:not_found)
      if conv.sandbox_id != observed.sandbox_id, do: Repo.rollback(:ownership_changed)
      turn = lock_turn(turn_id) || Repo.rollback(:not_found)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)
      existing = lock_execution_by_turn(turn_id)
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        existing && existing.connection_id == connection_id &&
            DateTime.compare(existing.deadline_at, deadline_at) == :eq ->
          {existing, nil, nil}

        existing ->
          Repo.rollback(:immutable_execution)

        turn.status != "running" ->
          Repo.rollback(:turn_not_running)

        DateTime.compare(deadline_at, now) != :gt ->
          Repo.rollback(:deadline_expired)

        open_execution?(conv.id) ->
          Repo.rollback(:execution_fenced)

        true ->
          sandbox = Repo.get(Sandbox, conv.sandbox_id) || Repo.rollback(:sandbox_not_found)
          if sandbox.user_id != conv.user_id, do: Repo.rollback(:ownership_changed)
          if sandbox.status != "ready", do: Repo.rollback(:sandbox_not_ready)

          prior = prior_connection(connection_id)
          if prior && prior.state != "completed", do: Repo.rollback(:connection_retired)

          if prior &&
               (prior.conversation_id != conv.id || prior.sandbox_id != sandbox.id ||
                  prior.sandbox_name != sandbox.sprite_name || prior.provider != sandbox.provider ||
                  prior.user_id != conv.user_id),
             do: Repo.rollback(:connection_owned_elsewhere)

          if prior && is_nil(prior.provider_session_id),
            do: Repo.rollback(:connection_unidentified)

          user = Repo.get!(Fountain.Accounts.User, conv.user_id)

          limits =
            case ExecutionLimits.for_new_turn(
                   ExecutionLimits.host_ceiling(),
                   user.execution_limits,
                   conv.execution_limits
                 ) do
              {:ok, limits} -> limits
              {:error, reason} -> Repo.rollback(reason)
            end

          enforce_deadline_ceiling!(turn, deadline_at, limits)

          attrs = %{
            execution_limits: limits,
            turn_id: turn.id,
            conversation_id: conv.id,
            user_id: conv.user_id,
            sandbox_id: sandbox.id,
            sandbox_name: sandbox.sprite_name,
            provider: sandbox.provider,
            connection_id: connection_id,
            provider_session_id: prior && prior.provider_session_id,
            deadline_at: deadline_at
          }

          case %TurnExecution{} |> TurnExecution.changeset(attrs) |> Repo.insert() do
            {:ok, execution} -> {execution, execution, "registered"}
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc "Record one spawn intent before opening its transport; an unknown spawn is never replayed."
  def _unsafe_claim_spawn(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "active" or not is_nil(execution.provider_session_id) or
            not is_nil(execution.spawn_submitted_at) ->
          Repo.rollback(:spawn_not_ready)

        DateTime.compare(now, execution.deadline_at) != :lt ->
          Repo.rollback(:deadline_expired)

        not match?(%Turn{status: "running"}, Repo.get(Turn, execution.turn_id)) ->
          Repo.rollback(:turn_not_running)

        not current_binding?(execution) ->
          Repo.rollback(:ownership_changed)

        true ->
          updated = update!(execution, %{spawn_submitted_at: now})
          {updated, updated, "spawn_submitted"}
      end
    end)
  end

  def _unsafe_bind_identity(id, connection_id, session_id) do
    if valid_session_id?(session_id) do
      with_execution(id, fn execution ->
        cond do
          execution.connection_id != connection_id ->
            Repo.rollback(:stale_connection)

          execution.provider_session_id == session_id ->
            {execution, nil, nil}

          execution.state not in [
            "active",
            "awaiting_identity",
            "ready",
            "submitted",
            "uncertain"
          ] ->
            Repo.rollback(:execution_closed)

          not is_nil(execution.provider_session_id) ->
            updated =
              update!(execution, %{state: "uncertain", last_error: "conflicting_identity"})

            fail_running_turn(execution.turn_id, DateTime.utc_now())
            {updated, updated, "identity_uncertain"}

          execution.state not in ["active", "awaiting_identity"] ->
            Repo.rollback(:execution_closed)

          is_nil(execution.spawn_submitted_at) ->
            Repo.rollback(:spawn_not_submitted)

          true ->
            state = if execution.state == "awaiting_identity", do: "ready", else: "active"
            updated = update!(execution, %{provider_session_id: session_id, state: state})
            {updated, updated, "identity_bound"}
        end
      end)
    else
      {:error, :invalid_session_id}
    end
  end

  @doc "A completion after the absolute deadline becomes a failed, fenced turn."
  def _unsafe_complete(id, status, opts \\ []) when status in @terminal_turns do
    with_execution(id, fn execution ->
      complete(execution, status, Keyword.get(opts, :now, DateTime.utc_now()))
    end)
  end

  @doc "Serialize the existing turn writer with deadline and termination state."
  def _unsafe_write_turn(%Turn{} = turn, attrs, writer) do
    case Repo.get_by(TurnExecution, turn_id: turn.id) do
      nil ->
        writer.(turn, attrs)

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()
          requested_status = attrs[:status] || attrs["status"]

          {decision, changed, event} =
            cond do
              requested_status in @terminal_turns ->
                complete(current, requested_status, now)

              current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt ->
                expire(current, now)

              true ->
                {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}
            end

          row = decision.turn || Repo.rollback(:turn_missing)

          protected =
            if decision.execution.state == "active",
              do: [],
              else: [:status, :exit_code, :ended_at, :pending_permission, :limit_reason]

          protected =
            if Map.get(decision, :terminal_changed, false),
              do: List.delete(protected, :exit_code),
              else: protected

          protected = protected ++ Enum.map(protected, &Atom.to_string/1)

          case writer.(row, Map.drop(attrs, protected)) do
            {:ok, result} -> {result, changed, event}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp complete(execution, status, now) do
    turn = lock_turn(execution.turn_id)

    cond do
      is_nil(turn) ->
        missing_turn(execution)

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt ->
        expire(execution, now)

      execution.state == "active" and not is_nil(execution.spawn_submitted_at) and
          is_nil(execution.provider_session_id) ->
        uncertain_spawn(execution, turn, now)

      execution.state == "active" and turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      execution.state == "active" and turn.status == "completed" ->
        updated = update!(execution, %{state: "completed"})
        {%{execution: updated, turn: turn}, updated, "completed"}

      execution.state == "active" and status in ["failed", "interrupted"] ->
        stop(execution, turn, status, now)

      execution.state == "active" and status == "completed" and
          is_nil(execution.provider_session_id) ->
        Repo.rollback(:execution_not_started)

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) == :lt ->
        updated = update!(execution, %{state: "completed"})
        turn = update!(turn, %{status: status, ended_at: DateTime.truncate(now, :second)})
        {%{execution: updated, turn: turn, terminal_changed: true}, updated, "completed"}

      true ->
        {%{execution: execution, turn: Repo.get(Turn, execution.turn_id)}, nil, nil}
    end
  end

  def _unsafe_expire(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      if execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt do
        expire(execution, now)
      else
        {%{execution: execution, turn: Repo.get(Turn, execution.turn_id)}, nil, nil}
      end
    end)
  end

  @doc "Serialize a terminal stage with expiration; reuse an existing deadline event."
  def _unsafe_terminal_stage(conv_id, turn_id, writer) do
    case Repo.get_by(TurnExecution, conversation_id: conv_id, turn_id: turn_id) do
      nil ->
        {:ok, {:new, writer.()}}

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()

          {decision, changed, event} =
            if current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt,
              do: expire(current, now),
              else: {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}

          result =
            if is_nil(decision.turn) || decision.execution.deadline_event_id ||
                 (decision.turn && decision.turn.limit_reason == "wall_time_limit") do
              id = decision.execution.deadline_event_id

              stored =
                if id,
                  do: Repo.get_by(LogEvent, id: id, conversation_id: conv_id, turn_id: turn_id)

              {:existing, stored}
            else
              {:new, writer.()}
            end

          {result, changed, event}
        end)
    end
  end

  @doc "Persist one provider-write attempt; never replay a submitted or uncertain attempt."
  def _unsafe_claim_termination(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "ready" ->
          Repo.rollback(:not_ready)

        not current_binding?(execution) ->
          updated = update!(execution, %{state: "uncertain", last_error: "ownership_changed"})
          {%{permitted: false, execution: updated}, updated, "termination_uncertain"}

        true ->
          updated =
            update!(execution, %{
              state: "submitted",
              attempt_id: Ecto.UUID.generate(),
              submitted_at: now
            })

          {%{permitted: true, execution: updated}, updated, "termination_submitted"}
      end
    end)
  end

  @doc "Apply only the result of the recorded attempt, including a late acknowledgment."
  def _unsafe_record_termination(id, attempt_id, result, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        is_nil(attempt_id) or execution.attempt_id != attempt_id ->
          Repo.rollback(:stale_attempt)

        execution.state == "stopped" and result == :ok ->
          {execution, nil, nil}

        execution.state not in ["submitted", "uncertain"] ->
          Repo.rollback(:execution_closed)

        execution.state == "uncertain" and execution.last_error != "termination_unconfirmed" ->
          Repo.rollback(:binding_uncertain)

        result == :ok ->
          updated = update!(execution, %{state: "stopped", confirmed_at: now, last_error: nil})
          {updated, updated, "termination_confirmed"}

        true ->
          updated =
            update!(execution, %{state: "uncertain", last_error: "termination_unconfirmed"})

          {updated, updated, "termination_uncertain"}
      end
    end)
  end

  @doc "Recover lost termination owners without authorizing another provider write."
  def _unsafe_recover_submissions(%DateTime{} = cutoff, limit \\ 50) when limit in 1..100 do
    ids =
      Repo.all(
        from e in TurnExecution,
          where: e.state == "submitted" and e.submitted_at <= ^cutoff,
          order_by: [asc: e.submitted_at, asc: e.id],
          limit: ^limit,
          select: e.id
      )

    Enum.map(ids, fn id ->
      with_execution(id, fn execution ->
        if execution.state == "submitted" and
             DateTime.compare(execution.submitted_at, cutoff) != :gt do
          updated =
            update!(execution, %{state: "uncertain", last_error: "termination_unconfirmed"})

          {updated, updated, "termination_uncertain"}
        else
          {execution, nil, nil}
        end
      end)
    end)
  end

  @doc "Rows needing deadline or termination handling; this read grants no provider write."
  def _unsafe_due(now \\ DateTime.utc_now(), limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: (e.state == "active" and e.deadline_at <= ^now) or e.state == "ready",
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit
    )
  end

  @doc "Deadline candidates only; pending provider cleanup must not starve expiration."
  def _unsafe_due_deadlines(now, limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: e.state == "active" and e.deadline_at <= ^now,
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit,
        select: e.id
    )
  end

  @doc "Known sessions awaiting their one termination claim, independently of deadlines."
  def _unsafe_ready_terminations(limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: e.state == "ready",
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit,
        select: e.id
    )
  end

  @doc "Unfinished remote work also prevents reset after its local turn has ended."
  def _unsafe_sandbox_open?(sandbox_id) do
    Repo.exists?(
      from e in TurnExecution,
        where: e.sandbox_id == ^sandbox_id and e.state not in ["completed", "stopped"]
    )
  end

  def _unsafe_fenced?(conversation_id) do
    Repo.exists?(
      from e in TurnExecution,
        where: e.conversation_id == ^conversation_id and e.state in ^@fenced
    )
  end

  defp expire(execution, now) do
    turn = lock_turn(execution.turn_id)

    # A different completion path may already have ended the row. It cannot
    # authorize terminating the connection now used by a later turn.
    cond do
      is_nil(turn) ->
        missing_turn(execution)

      turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      turn.status == "completed" ->
        updated = update!(execution, %{state: "completed"})
        {%{execution: updated, turn: turn}, updated, "completed"}

      true ->
        state =
          cond do
            execution.provider_session_id -> "ready"
            execution.spawn_submitted_at -> "awaiting_identity"
            true -> "stopped"
          end

        updated = update!(execution, %{state: state})

        turn =
          update!(turn, %{
            status: "failed",
            limit_reason: "wall_time_limit",
            exit_code: nil,
            ended_at: DateTime.truncate(now, :second),
            pending_permission: nil
          })

        # ownership: expire holds the original journal, parent and turn locks;
        # the event writer also checks the parent against the saved tenant.
        event_id = DeadlineEvents._unsafe_record!(updated, turn)
        updated = update!(updated, %{deadline_event_id: event_id})

        {%{execution: updated, turn: turn}, updated, "deadline_expired"}
    end
  end

  # A local failure or interruption is not evidence that the command stopped.
  # Retire this connection only after the same remote confirmation as a timeout.
  defp stop(execution, turn, status, now) do
    state =
      cond do
        execution.provider_session_id -> "ready"
        execution.spawn_submitted_at -> "awaiting_identity"
        true -> "stopped"
      end

    updated = update!(execution, %{state: state})
    changed = turn.status == "running"

    turn =
      if changed,
        do:
          update!(turn, %{
            status: status,
            ended_at: DateTime.truncate(now, :second),
            pending_permission: nil
          }),
        else: turn

    {%{execution: updated, turn: turn, terminal_changed: changed}, updated, "stop_requested"}
  end

  defp uncertain_spawn(execution, turn, now) do
    updated = update!(execution, %{state: "awaiting_identity", last_error: "spawn_unconfirmed"})

    turn =
      update!(turn, %{
        status: "failed",
        exit_code: nil,
        pending_permission: nil,
        ended_at: DateTime.truncate(now, :second)
      })

    {%{execution: updated, turn: turn}, updated, "spawn_uncertain"}
  end

  defp missing_turn(execution) do
    updated = update!(execution, %{state: "uncertain", last_error: "turn_missing"})
    {%{execution: updated, turn: nil}, updated, "termination_uncertain"}
  end

  defp fail_running_turn(turn_id, now) do
    case lock_turn(turn_id) do
      %Turn{status: "running"} = turn ->
        update!(turn, %{
          status: "failed",
          exit_code: nil,
          pending_permission: nil,
          ended_at: DateTime.truncate(now, :second)
        })

      _ ->
        :ok
    end
  end

  defp current_binding?(execution) do
    Repo.exists?(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where:
          c.id == ^execution.conversation_id and c.user_id == ^execution.user_id and
            s.id == ^execution.sandbox_id and s.user_id == ^execution.user_id and
            s.sprite_name == ^execution.sandbox_name and s.provider == ^execution.provider and
            s.status not in ["failed", "terminated"]
    )
  end

  defp with_execution(id, fun) do
    transaction(fn ->
      existing = Repo.get(TurnExecution, id) || Repo.rollback(:not_found)
      lock_parent(existing.conversation_id)
      execution = Repo.one!(from e in TurnExecution, where: e.id == ^id, lock: "FOR UPDATE")
      # Acquire every row lock before callbacks read the clock. A legacy writer
      # holding just the turn row must not extend a completion or spawn deadline.
      lock_turn(execution.turn_id)
      fun.(execution)
    end)
  end

  # Same namespace/order as sandbox reset: machine lock, then parent, then journal.
  # The reset retires its row under this lock before any provider I/O.
  defp lock_sandbox(id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])
  end

  defp lock_parent(id),
    do: Repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE")

  defp lock_execution_by_turn(id),
    do: Repo.one(from e in TurnExecution, where: e.turn_id == ^id, lock: "FOR UPDATE")

  defp lock_turn(id),
    do: Repo.one(from t in Turn, where: t.id == ^id, lock: "FOR UPDATE")

  defp prior_connection(connection_id),
    do:
      Repo.one(
        from e in TurnExecution,
          where: e.connection_id == ^connection_id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp open_execution?(conversation_id),
    do:
      Repo.exists?(
        from e in TurnExecution,
          where: e.conversation_id == ^conversation_id and e.state not in ["completed", "stopped"]
      )

  defp enforce_deadline_ceiling!(turn, deadline_at, %{"wall_time_seconds" => seconds}) do
    if is_nil(turn.started_at), do: Repo.rollback(:turn_not_started)
    ceiling = DateTime.add(turn.started_at, seconds, :second)

    if DateTime.compare(deadline_at, ceiling) == :gt,
      do: Repo.rollback({:execution_limits_widen, "wall_time_seconds"})
  end

  defp enforce_deadline_ceiling!(_turn, _deadline_at, _limits), do: :ok

  defp valid_session_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp update!(%TurnExecution{} = row, attrs),
    do: row |> TurnExecution.changeset(attrs) |> Repo.update!()

  defp update!(%Turn{} = row, attrs), do: row |> Turn.changeset(attrs) |> Repo.update!()

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, execution, event}} ->
        if event do
          Audit.record(%{
            user_id: execution.user_id,
            action: "conversation.execution_#{event}",
            resource_type: "conversation",
            resource_id: execution.conversation_id,
            actor: "system:turn_deadline",
            metadata: %{"turn_id" => execution.turn_id}
          })
        end

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
