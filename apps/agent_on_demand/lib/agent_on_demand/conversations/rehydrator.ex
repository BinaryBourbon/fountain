defmodule AgentOnDemand.Conversations.Rehydrator do
  @moduledoc """
  On app boot, find conversations whose ConversationServer would have been
  alive at the time of a clean BEAM stop and start servers for them.
  Scoped to sandbox.status == "ready" and conversation.status in ["idle", "running"].
  """
  require Logger
  alias AgentOnDemand.{Agents, Conversations, Runtimes}
  alias AgentOnDemand.Conversations.ConversationServer

  def run do
    AgentOnDemand.Telemetry.span([:rehydrate], %{}, fn ->
      convs = Conversations.list_resumable_conversations()
      Logger.info("rehydrator: scanning #{length(convs)} resumable conversation(s)")
      started = Enum.reduce(convs, 0, fn conv, count ->
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
           (conv.agent_id && Agents.get_agent(conv.agent_id, conv.user_id)) || {:skip, :no_agent},
         {:ok, runtime_module} <- Runtimes.for_runtime(conv.runtime) do
      Horde.DynamicSupervisor.start_child(
        AgentOnDemand.ConversationSupervisor,
        {ConversationServer, [
          conversation_id: conv.id,
          sandbox_id: conv.sandbox_id,
          runtime_module: runtime_module,
          initial_prompt: nil,
          user_id: conv.user_id
        ]}
      )
    else
      {:skip, why} -> Logger.warning("rehydrator: skipping conv #{conv.id} (#{why})"); :skipped
      {:error, reason} -> Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(reason)}"); :skipped
    end
  end
end
