# Run only against the disposable screenshot database, never a development or hosted database.
unless Mix.env() == :test and
         URI.parse(System.fetch_env!("DATABASE_URL")).path == "/fountain_capture_burndown" do
  raise "Use MIX_ENV=test and DATABASE_URL ending in /fountain_capture_burndown"
end

[project_id, item_id] = System.argv()

Application.put_env(
  :fountain,
  FountainWeb.Endpoint,
  Application.get_env(:fountain, FountainWeb.Endpoint) |> Keyword.put(:server, false)
)

{:ok, _} = Application.ensure_all_started(:fountain)
Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :auto)
import Ecto.Query
import Fountain.Factory
alias Fountain.Repo
alias Fountain.Conversations.{Conversation, Turn, LogEvent}

data =
  Jason.decode!(
    File.read!(System.get_env("CAPTURE_DATA_FILE", "/tmp/fountain-capture-data.json"))
  )

original = Repo.get!(Conversation, data["conv_id"]) |> Repo.preload(:agent)

sandbox =
  insert_sandbox(
    user_id: original.user_id,
    status: "suspended",
    sprite_name: "acorn-cart",
    environment_id: data["env_id"]
  )

conv =
  insert_conversation(
    user_id: original.user_id,
    agent: original.agent,
    sandbox: sandbox,
    status: "idle",
    title: "Builder: Make the empty cart feel useful",
    channel_id: "workbench:#{project_id}/#{item_id}/capture",
    acp: true
  )

original_turn = Repo.one!(from t in Turn, where: t.conversation_id == ^original.id)
turn = insert_turn(conv, prompt: original_turn.prompt, status: "completed")

for log <- Repo.all(from l in LogEvent, where: l.conversation_id == ^original.id, order_by: l.id) do
  insert_log_event(
    conv,
    Map.take(log, [:kind, :stage, :state, :stream, :data]) |> Map.put(:turn_id, turn.id)
  )
end

insert_log_event(conv,
  stream: "acp",
  turn_id: turn.id,
  data:
    Jason.encode!(%{
      jsonrpc: "2.0",
      method: "session/update",
      params: %{
        sessionId: "capture",
        update: %{
          sessionUpdate: "tool_call_update",
          toolCallId: "test-cart",
          status: "completed",
          rawOutput: "Cart.test.tsx: 8 tests passed"
        }
      }
    })
)
