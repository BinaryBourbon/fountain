# The required proof validates the dedicated local DB before any writes and
# exercises execution arbitration. This adds forced waits on machine ownership.
Code.require_file("scripts/verify-provision-ownership-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{ExecutionGuard, LogEvent, ProvisionContext, Sandbox, Turn, TurnExecution}
import Ecto.Query

for operation <- [:stage, :output, :failure, :broker_mint] do
  user = Repo.insert!(%Fountain.Accounts.User{email: "provision-owner-#{Ecto.UUID.generate()}@example.test"})
  source = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-source-#{Ecto.UUID.generate()}", status: "pending"})
  destination = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-target-#{Ecto.UUID.generate()}", status: "ready"})
  {:ok, parent} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: source.id, runtime: "claude", status: "pending"})
  {:ok, source} = Conversations.update_sandbox(source, %{status: "starting"})
  context = ProvisionContext.new(parent, source)
  owner = self()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      # Same numeric lock order as the real transfer. Keep the transaction open
      # until the old worker is confirmed waiting on a different connection.
      for key <- Enum.sort(Enum.uniq(Enum.map([source.id, destination.id], &:erlang.phash2/1))) do
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, key])
      end
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:holder, self(), backend})
      receive do
        :move -> :ok
      after
        5_000 -> raise "Transfer barrier timed out"
      end
      {:ok, moved} = Conversations.update_conversation(parent, %{sandbox_id: destination.id, status: "idle"})
      {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(%{conversation_id: moved.id, turn_number: 1, prompt: "local ownership proof", status: "running"}, destination.id, :unbounded)
      {:ok, execution} = ExecutionGuard._unsafe_register(turn.id, Ecto.UUID.generate(), DateTime.add(DateTime.utc_now(), 60))
      {turn.id, execution.id}
    end)
  end)
  holder_backend = receive do
    {:holder, pid, backend} when pid == holder.pid -> backend
  after
    5_000 -> raise "Transfer checkout timed out"
  end
  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:waiter, self(), backend})
      case operation do
        :stage -> ProvisionContext.stage(context, "setup", "failed", %{reason: "local late callback"})
        :output -> ProvisionContext.output(context, "setup", "local late output")
        :failure -> ProvisionContext.fail(context, %{reason: "local late callback"})
        :broker_mint -> Conversations.Egress.prepare(parent.id, %{}, %{}, provision_context: context)
      end
    end)
  end)
  waiter_backend = receive do
    {:waiter, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "Old worker checkout timed out"
  end
  true = holder_backend != waiter_backend
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  send(holder.pid, :move)
  {:ok, {turn_id, execution_id}} = Task.await(holder, 10_000)
  case operation do
    op when op in [:stage, :output] -> nil = Task.await(waiter, 10_000)
    op when op in [:failure, :broker_mint] -> {:error, :ownership_changed} = Task.await(waiter, 10_000)
  end
  true = Repo.reload!(parent).sandbox_id == destination.id
  "starting" = Repo.reload!(source).status
  "ready" = Repo.reload!(destination).status
  "running" = Repo.get!(Turn, turn_id).status
  "active" = Repo.get!(TurnExecution, execution_id).state
  false = Repo.exists?(from e in LogEvent, where: e.conversation_id == ^parent.id)
end

IO.puts("PROVISION_CONTEXT_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true,
  forced_lock_waits: 4,
  operations: ["stage", "output", "failure", "broker_mint"],
  replacement_execution_preserved: true,
  stale_failure_events: 0,
  provider_operations: 0,
  scope: "Local transfer commits and replacement admission before a stale worker acquires its original machine lock; does not prove same-machine actor epochs, provider identity or production behavior"
}))
