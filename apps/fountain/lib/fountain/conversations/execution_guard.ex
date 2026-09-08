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

  @doc "Atomically admit a turn and its execution journal before any preparation."
  def _unsafe_admit_turn(attrs, sandbox_id, capacity, writer) do
    transaction(fn ->
      conv_id = Map.fetch!(attrs, :conversation_id)
      lock_sandbox(sandbox_id)
      conv = lock_parent(conv_id) || Repo.rollback(:not_found)
      if conv.sandbox_id != sandbox_id, do: Repo.rollback(:ownership_changed)
      if conv.status in ["terminated", "failed"], do: Repo.rollback(:not_running)
      sandbox = require_ready_sandbox!(conv)
      if open_execution?(conv.id), do: Repo.rollback(:execution_fenced)

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

      case ExecutionLimits.require_controls(
             limits,
             ExecutionLimits.enforced_controls(conv.runtime)
           ) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      capacity =
        if capacity == :current_runtime,
          do: Fountain.RuntimeDispatch.concurrency(conv.runtime),
          else: capacity

      # ownership: conv is the locked parent for this actor and sandbox binding.
      if is_integer(capacity) and
           Fountain.Conversations._unsafe_running_turns_elsewhere(sandbox_id, conv.id) >= capacity,
         do: Repo.rollback(:sandbox_at_capacity)

      # The journal requires an absolute deadline. SDK-only requests cannot be
      # admitted through this transport by inventing an undocumented allowance.
      if map_size(limits) > 0 and not Map.has_key?(limits, "wall_time_seconds"),
        do: Repo.rollback({:execution_limits_invalid, "wall_time_seconds_required"})

      turn =
        case writer.() do
          {:ok, turn} -> turn
          {:error, reason} -> Repo.rollback(reason)
        end

      if map_size(limits) > 0 do
        if sandbox.provider != "sprites", do: Repo.rollback(:provider_not_supported)

        case Managoat.Runtimes.ACP.execution_limits(
               conv.runtime,
               ExecutionLimits.sdk_options(limits)
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        deadline = DateTime.add(turn.started_at, limits["wall_time_seconds"], :second)

        case _unsafe_register(turn.id, Ecto.UUID.generate(), deadline) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      conv |> Conversation.changeset(%{status: "running"}) |> Repo.update!()
      {turn, nil, nil}
    end)
  end

  @doc "An idle legacy connection cannot start background work after bounded policy is applied."
  def _unsafe_autonomous_turn(conversation_id, sandbox_id, writer) do
    transaction(fn ->
      lock_sandbox(sandbox_id)
      conv = lock_parent(conversation_id) || Repo.rollback(:not_found)
      if conv.sandbox_id != sandbox_id, do: Repo.rollback(:ownership_changed)
      if conv.status in ["terminated", "failed"], do: Repo.rollback(:not_running)
      require_ready_sandbox!(conv)
      user = Repo.get!(Fountain.Accounts.User, conv.user_id)

      case ExecutionLimits.for_new_turn(
             ExecutionLimits.host_ceiling(),
             user.execution_limits,
             conv.execution_limits
           ) do
        {:ok, limits} when map_size(limits) == 0 -> :ok
        _ -> Repo.rollback(:execution_fenced)
      end

      if open_execution?(conversation_id), do: Repo.rollback(:execution_fenced)

      case writer.() do
        {:ok, turn} ->
          conv |> Conversation.changeset(%{status: "running"}) |> Repo.update!()
          {turn, nil, nil}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc "Refuse a new prompt or wake while an earlier bounded execution is unresolved."
  def _unsafe_admission_gate(conversation_id) do
    transaction(fn ->
      lock_parent(conversation_id) || Repo.rollback(:not_found)
      if open_execution?(conversation_id), do: Repo.rollback(:execution_fenced)
      {:ok, nil, nil}
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Persist cancellation without waiting for the conversation actor or provider."
  def _unsafe_interrupt(conversation_id), do: interrupt(conversation_id, nil, nil)

  @doc "A starting actor may retire execution only on its original, still-owned machine."
  def _unsafe_interrupt_on_sandbox(conversation_id, sandbox_id, actor_claim \\ nil)
      when is_binary(sandbox_id),
      do: interrupt(conversation_id, sandbox_id, actor_claim)

  defp interrupt(conversation_id, expected_sandbox_id, actor_claim) do
    transaction(fn ->
      if expected_sandbox_id do
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          4316,
          :erlang.phash2(expected_sandbox_id)
        ])
      end

      parent = lock_parent(conversation_id) || Repo.rollback(:not_found)

      if expected_sandbox_id do
        sandbox =
          Repo.one(
            from s in Fountain.Conversations.Sandbox,
              where: s.id == ^expected_sandbox_id,
              lock: "FOR UPDATE"
          )

        unless sandbox && parent.sandbox_id == sandbox.id && parent.user_id == sandbox.user_id,
          do: Repo.rollback(:ownership_changed)

        unless Fountain.Conversations.ActorOwnership.current?(
                 parent.id,
                 sandbox.id,
                 actor_claim
               ),
               do: Repo.rollback(:ownership_changed)
      end

      cancelled_receipt = cancel_queued_prompt(parent, expected_sandbox_id)

      execution =
        Repo.one(
          from e in TurnExecution,
            where:
              e.conversation_id == ^conversation_id and e.state not in ["completed", "stopped"],
            order_by: [desc: e.inserted_at],
            limit: 1,
            lock: "FOR UPDATE"
        )

      if execution do
        lock_turn(execution.turn_id)
        {decision, changed, event} = complete(execution, "interrupted", DateTime.utc_now())
        {{:bounded, decision.execution.id}, changed, event}
      else
        # Queued user intent can coexist with an autonomous turn. Preserve the
        # ordinary actor interruption path while also cancelling the queued prompt.
        running? =
          Repo.exists?(
            from t in Turn,
              where: t.conversation_id == ^conversation_id and t.status == "running"
          )

        result =
          if cancelled_receipt && not running?, do: {:queued, cancelled_receipt}, else: :unbounded

        {result, nil, nil}
      end
    end)
  end

  # A user interrupt cancels queued intent in the same parent transaction as
  # execution retirement. Actor startup must leave that intent for delivery.
  defp cancel_queued_prompt(parent, nil) do
    delivery = Fountain.Conversations.PromptDelivery

    if receipt = delivery.queued(parent.user_id, parent.id) do
      case delivery.refuse(parent.user_id, parent.id, receipt.id, "cancelled") do
        {:ok, _} -> receipt.id
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp cancel_queued_prompt(_, _), do: nil

  @doc "Release only a durably idle parent; refusal never retires or interrupts execution."
  def _unsafe_release_parent(conversation_id, writer) do
    transaction(fn ->
      conv = lock_parent(conversation_id) || Repo.rollback(:not_running)

      running? =
        Repo.exists?(
          from t in Turn, where: t.conversation_id == ^conversation_id and t.status == "running"
        )

      queued? = Fountain.Conversations.PromptDelivery.queued(conv.user_id, conv.id)

      if running? or not is_nil(queued?) or open_execution?(conversation_id),
        do: Repo.rollback(:busy)

      case writer.(conv) do
        {:ok, updated} -> {%{applied: true, conversation: updated}, nil, nil}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Find the immutable journal for an already-owned actor's turn."
  def _unsafe_for_turn(turn_id), do: Repo.get_by(TurnExecution, turn_id: turn_id)

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

          # Bounded turns never inherit a warm process: it may retain background
          # work or SDK allowances from its previous prompt.
          if prior_connection(connection_id), do: Repo.rollback(:connection_retired)

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

  @doc "Authorize an immediate write to the original identified execution."
  def _unsafe_authorize_write(id, connection_id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.connection_id != connection_id ->
          Repo.rollback(:stale_connection)

        execution.state != "active" ->
          Repo.rollback(:execution_fenced)

        DateTime.compare(now, execution.deadline_at) != :lt ->
          {decision, changed, event} = expire(execution, now)
          {Map.put(decision, :permitted, false), changed, event}

        is_nil(execution.provider_session_id) ->
          Repo.rollback(:identity_unconfirmed)

        not match?(%Turn{status: "running"}, Repo.get(Turn, execution.turn_id)) ->
          Repo.rollback(:turn_not_running)

        not current_binding?(execution) ->
          Repo.rollback(:ownership_changed)

        true ->
          {%{permitted: true, execution: execution}, nil, nil}
      end
    end)
  end

  @doc "A completion after the absolute deadline becomes a failed, fenced turn."
  def _unsafe_complete(id, status, opts \\ []) when status in @terminal_turns do
    with_execution(id, fn execution ->
      complete(execution, status, Keyword.get(opts, :now, DateTime.utc_now()))
    end)
  end

  @doc "Serialize a turn's parent update with admission and retirement; callbacks only write rows."
  def _unsafe_write_parent(%Turn{} = observed, mode, writer) when mode in [:idle, :session] do
    transaction(fn ->
      conv = lock_parent(observed.conversation_id) || Repo.rollback(:not_found)
      execution = lock_execution_by_turn(observed.id)
      turn = lock_turn(observed.id) || Repo.rollback(:turn_missing)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)

      {execution, turn, changed, event} = parent_execution(execution, turn)

      allowed =
        latest_turn?(conv.id, turn.id) and parent_write_allowed?(conv, turn, execution, mode)

      if allowed do
        case writer.(conv) do
          {:ok, updated} -> {%{applied: true, conversation: updated}, changed, event}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {%{applied: false, conversation: conv}, changed, event}
      end
    end)
  end

  @doc "Retire an orphan's execution before recovery writes, in parent/journal/turn lock order."
  def _unsafe_recover_turn(%Turn{} = observed, writer) do
    transaction(fn ->
      conv = lock_parent(observed.conversation_id) || Repo.rollback(:not_found)
      execution = lock_execution_by_turn(observed.id)
      turn = lock_turn(observed.id) || Repo.rollback(:turn_missing)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)

      if execution && not cleanup_binding?(execution), do: Repo.rollback(:ownership_changed)
      running? = turn.status == "running"
      {turn, changed, event} = retire_orphan(execution, turn)

      if running? do
        result = writer.(turn, conv, latest_turn?(conv.id, turn.id), not is_nil(execution))
        {result, changed, event}
      else
        {:noop, changed, event}
      end
    end)
  end

  defp retire_orphan(nil, turn), do: {turn, nil, nil}

  defp retire_orphan(execution, turn) do
    status = if turn.status == "running", do: "interrupted", else: turn.status
    {decision, changed, event} = complete(execution, status, DateTime.utc_now())
    {decision.turn, changed, event}
  end

  defp latest_turn?(conv_id, turn_id) do
    Repo.one(
      from t in Turn,
        where: t.conversation_id == ^conv_id,
        order_by: [desc: t.turn_number],
        limit: 1,
        select: t.id
    ) == turn_id
  end

  @doc "An idle legacy connection may clear only its unchanged session, before any successor starts."
  def _unsafe_clear_idle_session(conv_id, expected, writer) do
    transaction(fn ->
      conv = lock_parent(conv_id) || Repo.rollback(:not_found)

      running? =
        Repo.exists?(
          from t in Turn, where: t.conversation_id == ^conv_id and t.status == "running"
        )

      bounded? = Repo.exists?(from e in TurnExecution, where: e.conversation_id == ^conv_id)

      if conv.status in ["running", "idle"] and conv.runtime_session_id == expected and
           not running? and not bounded? do
        case writer.(conv) do
          {:ok, updated} -> {%{applied: true, conversation: updated}, nil, nil}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {%{applied: false, conversation: conv}, nil, nil}
      end
    end)
  end

  defp parent_execution(nil, turn), do: {nil, turn, nil, nil}

  defp parent_execution(execution, turn) do
    now = DateTime.utc_now()

    if execution.state == "active" and current_binding?(execution) and
         DateTime.compare(now, execution.deadline_at) != :lt do
      {decision, changed, event} = expire(execution, now)
      {decision.execution, decision.turn, changed, event}
    else
      {execution, turn, nil, nil}
    end
  end

  defp parent_write_allowed?(conv, turn, execution, mode) do
    bound? = is_nil(execution) or current_binding?(execution)

    case mode do
      :idle ->
        bound? and conv.status == "running" and turn.status in @terminal_turns and
          (is_nil(execution) or execution.state != "active")

      :session ->
        bound? and conv.status in ["running", "idle"] and turn.status == "running" and
          (is_nil(execution) or execution.state == "active")
    end
  end

  @doc "Serialize transcript writes with retirement; the callback must contain only database work."
  def _unsafe_write_event(conv_id, turn_id, writer) do
    case turn_id && Repo.get_by(TurnExecution, turn_id: turn_id) do
      nil ->
        {:ok, writer.()}

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()

          cond do
            current.conversation_id != conv_id or not current_binding?(current) ->
              {nil, nil, nil}

            current.state != "active" ->
              {nil, nil, nil}

            DateTime.compare(now, current.deadline_at) != :lt ->
              {_decision, changed, event} = expire(current, now)
              {nil, changed, event}

            not match?(%Turn{status: "running"}, Repo.get(Turn, current.turn_id)) ->
              {nil, nil, nil}

            true ->
              {writer.(), nil, nil}
          end
        end)
    end
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

          # Once retired, a stale actor cannot rewrite its prompt, selection,
          # reply or permission state. The winning terminal transition may
          # retain its exit code; delayed usage has its own once-only writer.
          allowed =
            cond do
              decision.execution.state == "active" ->
                attrs

              Map.get(decision, :terminal_changed, false) ->
                Map.take(attrs, [:exit_code, "exit_code"])

              true ->
                %{}
            end

          case writer.(row, allowed) do
            {:ok, result} -> {result, changed, event}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp complete(execution, status, now) do
    turn = lock_turn(execution.turn_id)

    cond do
      is_nil(turn) and execution.state == "active" ->
        missing_turn(execution)

      is_nil(turn) ->
        {%{execution: execution, turn: nil}, nil, nil}

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt ->
        expire(execution, now)

      execution.state == "active" and not is_nil(execution.spawn_submitted_at) and
          is_nil(execution.provider_session_id) ->
        uncertain_spawn(execution, turn, now)

      execution.state == "active" and turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      execution.state == "active" and turn.status == "completed" ->
        stop(execution, turn, "completed", now)

      execution.state == "active" and status in ["failed", "interrupted"] ->
        stop(execution, turn, status, now)

      execution.state == "active" and status == "completed" and
          is_nil(execution.provider_session_id) ->
        Repo.rollback(:execution_not_started)

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) == :lt ->
        stop(execution, turn, status, now)

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
  def _unsafe_terminal_stage(conv_id, turn_id, status, writer) do
    case Repo.get_by(TurnExecution, turn_id: turn_id) do
      nil ->
        {:ok, {:new, writer.()}}

      execution when execution.conversation_id != conv_id ->
        {:ok, {:existing, nil}}

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()

          {decision, changed, event} =
            if current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt,
              do: expire(current, now),
              else: {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}

          result = terminal_event(decision, conv_id, turn_id, status, writer)

          {result, changed, event}
        end)
    end
  end

  defp terminal_event(decision, conv_id, turn_id, status, writer) do
    execution = decision.execution
    turn = decision.turn

    cond do
      execution.conversation_id != conv_id or is_nil(turn) ->
        {:existing, nil}

      execution.deadline_event_id || turn.limit_reason == "wall_time_limit" ->
        stored =
          if execution.deadline_event_id,
            do:
              Repo.get_by(LogEvent,
                id: execution.deadline_event_id,
                conversation_id: conv_id,
                turn_id: turn_id
              )

        {:existing, stored}

      not current_binding?(execution) ->
        {:existing, nil}

      Map.get(
        %{"done" => "completed", "failed" => "failed", "interrupted" => "interrupted"},
        status
      ) != turn.status ->
        {:existing, nil}

      true ->
        {:new, writer.()}
    end
  end

  @doc "Persist one provider-write attempt; never replay a submitted or uncertain attempt."
  def _unsafe_claim_termination(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "ready" ->
          Repo.rollback(:not_ready)

        not cleanup_binding?(execution) ->
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
        stop(execution, turn, "completed", now)

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

  # No local turn outcome proves the command stopped. Even a successful reply
  # may leave background work; every bounded connection requires remote cleanup.
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

  # A persisted retirement survives parent deletion. The original sandbox row
  # must still prove its tenant/name/provider binding; a surviving conversation
  # must also remain bound to it. Missing or changed sandbox identity stays
  # uncertain. Reset cannot reuse this row while its journal remains open.
  defp cleanup_binding?(execution) do
    sandbox_matches =
      Repo.exists?(
        from s in Sandbox,
          where:
            s.id == ^execution.sandbox_id and s.user_id == ^execution.user_id and
              s.sprite_name == ^execution.sandbox_name and s.provider == ^execution.provider
      )

    parent_matches =
      case Repo.get(Conversation, execution.conversation_id) do
        nil -> true
        conv -> conv.user_id == execution.user_id and conv.sandbox_id == execution.sandbox_id
      end

    sandbox_matches and parent_matches
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

  # All turn sources participate in reset's machine lock, including unlimited
  # background work. The row check happens after that lock, before any writer.
  defp require_ready_sandbox!(conv) do
    sandbox =
      Repo.one(from s in Sandbox, where: s.id == ^conv.sandbox_id, lock: "FOR UPDATE") ||
        Repo.rollback(:sandbox_not_found)

    if sandbox.user_id != conv.user_id, do: Repo.rollback(:ownership_changed)
    if sandbox.status != "ready", do: Repo.rollback(:sandbox_not_ready)

    # ownership: the locked machine belongs to the locked conversation above.
    if Fountain.Conversations.SandboxTransitions._unsafe_pending?(sandbox.id),
      do: Repo.rollback(:provider_operation_fenced)

    sandbox
  end

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
