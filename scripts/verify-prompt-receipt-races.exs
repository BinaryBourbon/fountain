# Reuses the local-only database guard and independent-connection barrier.
Code.require_file("scripts/verify-turn-deadline-races.exs")

alias Fountain.Repo
alias Fountain.Conversations.{ExecutionGuard, LogEvent, PromptDelivery, PromptReceipt, Turn}
import Ecto.Query

fixture = fn ->
  user = Fountain.Factory.insert_verified_user(email: "prompt-race-#{Ecto.UUID.generate()}@example.test")
  sandbox = Fountain.Factory.insert_sandbox(user_id: user.id, status: "ready", sprite_name: "local-prompt-proof-#{Ecto.UUID.generate()}")
  conv = Fountain.Factory.insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
  {user, sandbox, conv}
end

outcomes = for _ <- 1..10 do
  {user, sandbox, conv} = fixture.()
  submit = fn key -> PromptDelivery.submit(user.id, conv.id, "local receipt proof", [], idempotency_key: key) end
  [{:ok, a}, {:ok, b}] = DeadlineRace.concurrently([fn -> submit.("same") end, fn -> submit.("same") end])
  true = a.id == b.id
  1 = Repo.aggregate(from(t in Turn, where: t.conversation_id == ^conv.id), :count)

  results = DeadlineRace.concurrently([
    fn -> PromptDelivery._unsafe_activate(conv.id, a.id, sandbox.id) end,
    fn -> PromptDelivery._unsafe_activate(conv.id, a.id, sandbox.id) end
  ])
  1 = Enum.count(results, &match?({:ok, %Turn{}}, &1))
  1 = Enum.count(results, &match?({:error, :delivery_claimed}, &1))
  "claimed" = Repo.reload!(a).state
  "running" = Repo.get!(Turn, a.turn_id).status

  {user, _, conv} = fixture.()
  results = DeadlineRace.concurrently(Enum.map(["one", "two"], fn key ->
    fn -> PromptDelivery.submit(user.id, conv.id, "local distinct request", [], idempotency_key: key) end
  end))
  1 = Enum.count(results, &match?({:ok, %PromptReceipt{}}, &1))
  1 = Enum.count(results, &match?({:error, :busy}, &1))
  1 = Repo.aggregate(from(t in Turn, where: t.conversation_id == ^conv.id), :count)

  {user, sandbox, conv} = fixture.()
  {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "local cancellation proof", [], idempotency_key: "cancel")
  [activation, cancellation] = DeadlineRace.concurrently([
    fn -> PromptDelivery._unsafe_activate(conv.id, receipt.id, sandbox.id) end,
    fn -> ExecutionGuard._unsafe_interrupt(conv.id) end
  ])
  current = Repo.reload!(receipt)
  case current.state do
    "claimed" ->
      {:ok, %Turn{status: "running"}} = activation
      {:ok, :unbounded} = cancellation
      "running" = Repo.get!(Turn, receipt.turn_id).status
      "activation_won"
    "refused" ->
      {:error, :delivery_claimed} = activation
      {:ok, {:queued, _}} = cancellation
      "failed" = Repo.get!(Turn, receipt.turn_id).status
      "cancellation_won"
  end
end

# The accepting boundary can race too. These fixtures deliberately have no
# agent, so the real wake refuses locally without any provider request.
for _ <- 1..10 do
  {user, _, conv} = fixture.()
  true = is_nil(conv.agent_id)
  [first, second] = DeadlineRace.concurrently([
    fn -> PromptDelivery.accept(user.id, conv.id, "local accepting boundary", [], idempotency_key: "accept") end,
    fn -> PromptDelivery.accept(user.id, conv.id, "local accepting boundary", [], idempotency_key: "accept") end
  ])
  {:ok, a} = first
  {:ok, b} = second
  true = a.id == b.id
  "refused" = Repo.reload!(a).state
  "failed" = Repo.get!(Turn, a.turn_id).status
  1 = Repo.aggregate(from(e in LogEvent, where: e.turn_id == ^a.turn_id), :count)
  1 = Repo.aggregate(from(t in Turn, where: t.conversation_id == ^conv.id), :count)
end

# Duplicate expiry and a late activation must agree on one persisted failure.
for _ <- 1..10 do
  {user, sandbox, conv} = fixture.()
  {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "local expiry proof", [])
  receipt |> Ecto.Changeset.change(delivery_deadline_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()
  [first, second, activation] = DeadlineRace.concurrently([
    fn -> PromptDelivery.refuse(user.id, conv.id, receipt.id, "delivery_expired") end,
    fn -> PromptDelivery.refuse(user.id, conv.id, receipt.id, "delivery_expired") end,
    fn -> PromptDelivery._unsafe_activate(conv.id, receipt.id, sandbox.id) end
  ])
  {:ok, %PromptReceipt{state: "refused"}} = first
  {:ok, %PromptReceipt{state: "refused"}} = second
  true = activation in [{:error, :delivery_expired}, {:error, :delivery_claimed}]
  "failed" = Repo.get!(Turn, receipt.turn_id).status
  1 = Repo.aggregate(from(e in LogEvent, where: e.turn_id == ^receipt.turn_id), :count)
end

# Force the actor to arrive before expiry but obtain its final row lock afterward.
for lock_table <- ["conversations", "prompt_receipts", "turns"] do
  {user, sandbox, conv} = fixture.()
  {:ok, receipt} = PromptDelivery.submit(user.id, conv.id, "local delayed activation", [])
  deadline = DateTime.add(DateTime.utc_now(), 2)
  receipt |> Ecto.Changeset.change(delivery_deadline_at: deadline) |> Repo.update!()
  lock_id = case lock_table do
    "conversations" -> conv.id
    "prompt_receipts" -> receipt.id
    "turns" -> receipt.turn_id
  end
  owner = self()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM #{lock_table} WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(lock_id)])
      send(owner, :locked)
      receive do
        :release -> :ok
      after
        10_000 -> raise "Prompt lock release timed out"
      end
    end)
  end)
  receive do
    :locked -> :ok
  after
    10_000 -> raise "Prompt lock acquisition timed out"
  end
  claim = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:claim_backend, backend})
      PromptDelivery._unsafe_activate(conv.id, receipt.id, sandbox.id)
    end)
  end)
  backend = receive do
    {:claim_backend, backend} -> backend
  after
    1_000 -> raise "Prompt claim checkout timed out"
  end
  waiting = Enum.reduce_while(1..100, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  true = waiting
  :lt = DateTime.compare(DateTime.utc_now(), deadline)
  Process.sleep(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 50)
  send(holder.pid, :release)
  Task.await(holder)
  {:error, :delivery_expired} = Task.await(claim)
  "queued" = Repo.reload!(receipt).state
  "pending" = Repo.get!(Turn, receipt.turn_id).status
end

IO.puts("PROMPT_RECEIPT_RACE_RESULT=" <> Jason.encode!(%{
  separate_database_connections: true,
  duplicate_submission_races: 10,
  duplicate_acceptance_races: 10,
  duplicate_activation_races: 10,
  distinct_submission_races: 10,
  user_interrupt_activation_races: 10,
  duplicate_expiry_activation_races: 10,
  forced_activation_deadline_lock_waits: 3,
  cancellation_outcomes: Enum.frequencies(outcomes),
  provider_operations: 0,
  scope: "Local receipt arbitration only; Initial creation, legacy wake and end-to-end restart recovery remain integration work"
}))
