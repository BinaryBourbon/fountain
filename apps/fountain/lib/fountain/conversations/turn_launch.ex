defmodule Fountain.Conversations.TurnLaunch do
  @moduledoc """
  Launch a fresh command for a turn the actor has already admitted.

  Extracted from `ConversationServer.run_fresh_turn/7` unchanged: the actor is
  the largest module in the system and its line count only ratchets down
  (`conversation_server_size_test.exs`), so the bounded-turn lifecycle #1749
  adds has to buy its room from somewhere. This is the natural seam — a pure
  launch, given a state it does not own and returning it.

  `fail_before_start` is the actor's own pre-start failure path, passed in
  rather than duplicated: it writes buffered output through the actor's logger
  and clears `current_turn`, both of which are the actor's business.

  Nothing here is bounded-turn specific. `run_turn/6` decides whether a turn is
  bounded and which transport it gets; by the time this runs that is settled.
  """
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{CodexChatGPT, Connection, ExecutionLimits}
  alias Fountain.Conversations.{McpServers, Output, TurnMachine}

  def run(state, conv, turn, prompt, agent, images, acp?, fail_before_start) do
    turn_number = turn.turn_number

    # Write image temp files to sprite. Only on the legacy path: ACP carries
    # images as content blocks inside `session/prompt`, so writing them into
    # the sandbox first would be a round trip whose product nothing reads.
    image_paths =
      if acp?, do: [], else: Output.write_image_temp_files(state.handle, turn.id, images)

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

    {mode, runtime_session_id} = TurnMachine.session_plan(conv, state.runtime_session_id)

    {cmd, args, build_opts} =
      TurnMachine.command(acp?, conv, agent, prompt, mode, runtime_session_id,
        handle: state.handle,
        runtime_module: state.runtime_module,
        image_paths: image_paths
      )

    # If a runtime embeds the prompt in argv (codex), it returns
    # `stdin?: false` and we skip the write_stdin/close_stdin pipeline.
    # claude / gemini / opencode default to true and read from stdin.
    use_stdin? = Keyword.get(build_opts, :stdin?, true)

    # codex emits a noisy "additional input from stdin" warning when
    # `isatty(0)` is false; allocating a PTY suppresses it. Other
    # runtimes default to no PTY.
    use_tty? = Keyword.get(build_opts, :tty?, false)

    # opencode + gemini set this to point at a workspace dir that has a
    # local .git (so neither runtime trips on /home/sprite's perms).
    cwd = Keyword.get(build_opts, :dir)

    # Runtimes that cannot accept images as CLI flags (claude, gemini)
    # return a prompt_suffix with image references to append to stdin.
    prompt_suffix = Keyword.get(build_opts, :prompt_suffix, "")

    Output.publish_stage(state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn_number,
      mode: Atom.to_string(mode)
    })

    # Open an OTel span for the turn. We can't use Telemetry.span here
    # because the turn finishes asynchronously (in the :exit handler);
    # so we open it explicitly and store the span context in state to
    # close it later. While this span is current, build_sprite_env
    # picks up the trace context as TRACEPARENT for the runtime CLI.
    turn_span = TurnMachine.open_span(state.user_id, conv, turn, mode, agent)
    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    # Tag the detachable session with this conversation, on its own command
    # line, so a reattach after a deploy can tell it from another
    # conversation's process on the same machine (ADR 0023 gate 1).
    {cmd, args} = Fountain.Conversations.Identity.tag_command(state.conversation_id, cmd, args)

    # Stamped before the spawn so the duration covers the round trip to
    # sprites.dev — that latency is part of what the user waits through.
    # Kept local until the spawn succeeds: a spawn that never starts has no
    # run to time, and a stamp left in state would attach itself to the
    # next turn.
    turn_started_mono = System.monotonic_time(:millisecond)

    try do
      spawn_opts =
        [
          env: state.sprite_env,
          owner: self(),
          stdin: use_stdin?,
          tty: use_tty?,
          # Detachable: the sprite-side session survives a WebSocket
          # disconnect, so a BEAM restart can list_sessions + reattach.
          detachable: true
        ]
        |> then(&if cwd, do: Keyword.put(&1, :dir, cwd), else: &1)

      # A bounded turn goes through the supervised transport, which records
      # spawn intent before any I/O and keeps stdin closed until the provider
      # names its session (ADR 0046). Everything else keeps the legacy spawn.
      spawn_result =
        if state.turn_execution do
          # ownership: admission registered this actor's turn against its
          # persisted tenant and sandbox.
          Connection._unsafe_spawn_bounded(state, conv.runtime, cmd, args, spawn_opts)
        else
          with {:ok, command} <-
                 Connection.spawn_command(state, conv.runtime, cmd, args, spawn_opts),
               do: {:ok, command, nil}
        end

      case spawn_result do
        {:ok, command, transport} ->
          # write_stdin/2 is total by contract — a runtime that exits before
          # reading its prompt yields {:error, :command_exited} rather than
          # taking this server down (#603).
          # On the ACP path stdin stays **open**: it is the return path for
          # `session/request_permission` answers and `session/cancel`, and the
          # peer writes the prompt itself as `session/prompt`. Closing it here
          # would hang up on the agent mid-handshake. It is closed when the
          # turn ends — see `finish_turn/4`.
          stdin_result =
            cond do
              acp? -> :ok
              use_stdin? -> TurnMachine.write_prompt_and_close(command, prompt <> prompt_suffix)
              true -> :ok
            end

          case stdin_result do
            :ok ->
              # Tool-span tracing. Every ACP turn gets it, whatever the runtime
              # — `session/update` carries the id and status the tracer keys on
              # (#637). The legacy path traces nothing: its only tracer was a
              # parser over claude's dialect, deleted with that path.
              stream_tracer = if acp?, do: Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")

              {peer, peer_mon} =
                if acp? do
                  TurnMachine.start_acp_peer(command, prompt, mode, runtime_session_id,
                    cwd: cwd,
                    images: images,
                    mcp_servers:
                      McpServers.for_session(agent, conv,
                        user_id: state.user_id,
                        conversation_id: state.conversation_id,
                        callback_token: state.callback_token,
                        resolved: state.resolved_mcp_servers
                      ),
                    model: TurnMachine.acp_model(conv, agent),
                    permission_policy: TurnMachine.effective_permission_policy(conv, agent),
                    auth:
                      CodexChatGPT.peer_auth(state.runtime_module, state.inference_credentials),
                    execution_transport: transport,
                    execution_limits: bounded_sdk_limits(state, conv.runtime)
                  )
                else
                  {nil, nil}
                end

              %{
                state
                | current_command: command,
                  execution_transport: transport,
                  current_command_ref: command.ref,
                  current_turn: turn,
                  runtime_session_id: runtime_session_id,
                  current_turn_span: turn_span,
                  turn_metrics:
                    TurnMachine.start_metrics(
                      conv.runtime,
                      state.handle.provider,
                      turn_started_mono
                    ),
                  stream_tracer: stream_tracer,
                  acp_peer: peer,
                  acp_peer_mon: peer_mon
              }

            {:error, reason} ->
              # The runtime exited before it read the prompt, so nothing is
              # running and no output will ever arrive: a spawn-level failure
              # in every way that matters. The turn ends `failed` naming the
              # reason instead of the server dying and its restart orphaning
              # the turn behind a reattach.
              #
              # Take the runtime's exit code and last words with us (#608).
              # `:command_exited` names the mechanism; the code and whatever
              # it printed on the way out are the diagnosis, and they are
              # already sitting in our mailbox.
              {exit_code, output} = TurnMachine.drain_exited_command(command.ref)

              fail_before_start.(
                state,
                turn,
                reason,
                "prompt write failed",
                exit_code,
                output
              )
          end

        {:error, reason} ->
          fail_before_start.(state, turn, reason, "spawn failed", nil, [])
      end
    after
      # The successful path keeps the span open until :exit; the error
      # path above closes it explicitly. In both cases we restore the
      # caller's previous current-span here.
      OpenTelemetry.Tracer.set_current_span(previous_span)
    end
  end

  # A turn that never got as far as running (`TurnMachine.fail_before_start/5`):
  # the spawn failed, or the runtime exited before the prompt reached its
  # stdin (#603). The server's half is the runtime's parting words (#608),
  # persisted through the output path against the turn they explain.
  #
  # Called only from inside kick_turn's try block, which restores the caller's
  # previous current-span in its `after`; the span this ends is the turn span
  # kick_turn opened a few lines above the call.

  # The SDK's own view of the allowance, from the frozen journal copy rather
  # than from current policy: an in-flight turn keeps what it was admitted
  # under. Nil for an unbounded turn, which asks the SDK for nothing.
  defp bounded_sdk_limits(%{turn_execution: nil}, _runtime), do: nil

  # The hard match is safe at a distance, which is worth saying rather than
  # leaving to be rediscovered: admission already called
  # `Managoat.Runtimes.ACP.execution_limits/2` for this runtime and allowance
  # inside `_unsafe_register_bounded/3`, through a `with` that rolls the turn
  # back on `{:error, _}`. A journal row therefore cannot exist for a runtime
  # that refuses its own limits, so reaching here with one is a bug in
  # admission and crashing is the right answer to it.
  defp bounded_sdk_limits(state, runtime) do
    options = ExecutionLimits.sdk_options(state.turn_execution.execution_limits)
    {:ok, limits} = Managoat.Runtimes.ACP.execution_limits(runtime, options)
    limits
  end
end
