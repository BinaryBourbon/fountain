defmodule Fountain.Conversations.ProvisionWatchdog do
  @moduledoc """
  The absolute deadline on `ConversationServer`'s provisioning.

  It cannot live inside that server: a stuck `handle_continue(:provision)`
  blocks the mailbox, so a `send_after` (or a trapped exit signal) queues
  behind the very thing it is meant to bound. The watchdog is a separate
  process that, at the deadline, consults the sandbox row — the provision
  path's own source of truth — and only if it is still pending/starting
  brutally kills the server and applies the same failed/failed row
  transitions as the normal provision-failure path. The sprite, if one was
  created, is picked up by SandboxReaper's untracked sweep. A monitor exits
  the watchdog quietly whenever the server stops first, which covers every
  success and ordinary-failure path.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Output}

  # Absolute ceiling on provisioning (#329). Generous against the summed
  # default step timeouts (packages 300s + clone 600s + setup 120s). Setup
  # may opt into up to 900s, but this overall ceiling still applies. It also
  # catches a step that stalls without raising — the case where
  # the row sat in `starting` holding a quota slot until the next deploy:
  # the reaper exempts rows whose server is alive, and the server's own
  # timers queue behind the stuck handle_continue. Overridable in tests.
  @provision_deadline_ms :timer.minutes(30)

  @doc """
  Start the watchdog for the calling server. Returns the watchdog's pid.
  """
  @spec start(String.t(), String.t() | nil) :: pid()
  def start(conv_id, sandbox_id) do
    server = self()
    deadline_ms = Application.get_env(:fountain, :provision_deadline_ms, @provision_deadline_ms)

    spawn(fn ->
      ref = Process.monitor(server)

      receive do
        {:DOWN, ^ref, :process, ^server, _reason} -> :ok
      after
        deadline_ms ->
          # ownership: the two ids are the ones the ConversationServer was
          # started with, and it established ownership of both at init. The
          # watchdog reads no row it was not handed.
          sandbox = Conversations._unsafe_get_sandbox!(sandbox_id)

          if sandbox.status in ["pending", "starting"] do
            Logger.error(
              "conv #{conv_id}: provisioning exceeded #{deadline_ms}ms; " <>
                "failing the sandbox and killing the stuck server"
            )

            # Rows BEFORE the kill (#394). The server is restart: :transient
            # and :killed is an abnormal exit, so a kill-first ordering let
            # Horde restart it into handle_continue(:provision) while the row
            # still said pending — and the restart re-provisioned a second
            # billable sprite, then kept streaming into it while this stale
            # struct's late "failed" write made the row lie about it. With
            # the terminal status committed first, a restarted server stops
            # at the terminal-status guard in :provision.
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

            # ownership: as the sandbox read above.
            case Conversations._unsafe_get_conversation(conv_id) do
              %Conversation{status: status} = conv when status not in ["terminated", "failed"] ->
                Conversations.update_conversation(conv, %{status: "failed"})

              _ ->
                :ok
            end

            Output.publish_stage(conv_id, "provision", "failed", %{
              reason: "provision deadline exceeded"
            })

            # Prefer supervisor termination over Process.exit: it removes the
            # child, so no restart happens at all, and it bounds the wait —
            # the server traps exits and is stuck in a callback, so the
            # :shutdown signal queues until the child-spec shutdown timeout
            # expires and the supervisor escalates to :kill. terminate/2
            # still does not run for the stuck server; expires_at bounds the
            # un-revoked callback key, and the reaper reclaims the sprite.
            # The fallback covers a server not running under the supervisor
            # (tests) or one that died in the meantime.
            case Horde.DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, server) do
              :ok -> :ok
              {:error, _} -> Process.exit(server, :kill)
            end

            :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
              conversation_id: conv_id
            })
          end
      end
    end)
  end
end
