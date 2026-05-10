defmodule Fountain.Conversations.Rehydrator do
  @moduledoc """
  On app boot, find conversations whose ConversationServer would have been
  alive at the time of a clean BEAM stop and start servers for them. Each
  server enters reattach mode: get a sprite handle without recreating,
  verify the sprite is still alive at sprites.dev, mark the sandbox failed
  if it isn't.

  Scoped to **fully-provisioned** conversations (sandbox.status == "ready"
  and conversation.status in ["idle", "running"]). Pending/starting
  sandboxes from a crashed mid-provision are left as-is — the user's next
  action lazily resolves them via `wake_conversation`.
  """

  require Logger

  alias Fountain.{Agents, Conversations, Runtimes}
  alias Fountain.Conversations.ConversationServer

  def run do
    Fountain.Telemetry.span([:rehydrate], %{}, fn ->
      convs = Conversations.list_resumable_conversations()
      Logger.info("rehydrator: scanning #{length(convs)} resumable conversation(s)")

      started =
        Enum.reduce(convs, 0, fn conv, count ->
          case spawn_server(conv) do
            {:ok, _pid} -> count + 1
            _ -> count
          end
        end)

      Logger.info("rehydrator: started #{started} ConversationServer(s)")
      {started, %{candidates: length(convs), started: started}}
    end)
  end

  defp spawn_server(conv) do
    with %Agents.Agent{} = _agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:skip, :no_agent},
         {:ok, runtime_module} <- Runtimes.for_runtime(conv.runtime) do
      Horde.DynamicSupervisor.start_child(
        Fountain.ConversationSupervisor,
        {ConversationServer,
         [
           conversation_id: conv.id,
           sandbox_id: conv.sandbox_id,
           runtime_module: runtime_module,
           initial_prompt: nil
         ]}
      )
    else
      {:skip, why} ->
        Logger.warning("rehydrator: skipping conv #{conv.id} (#{why})")
        :skipped

      {:error, reason} ->
        Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(reason)}")
        :skipped
    end
  end
end
