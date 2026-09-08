# Checked-in prelude enforces a local/test database and independent backend PIDs.
Code.require_file("scripts/verify-turn-deadline-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Conversation, Sandbox, SandboxOperations, SandboxTransitions}
alias Managoat.Sandbox.Handle

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "transition-#{Ecto.UUID.generate()}@example.test"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-transition-#{Ecto.UUID.generate()}", mode: "ephemeral", status: "pending"})
  conv = Repo.insert!(%Conversation{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
  {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)
  handle = %Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: Ecto.UUID.generate()}
  {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})
  {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
  attrs = %{conversation_id: conv.id, turn_number: 1, prompt: "local transition race", status: "running", started_at: DateTime.utc_now()}
  {sandbox, conv, attrs}
end

admit = fn source, sandbox, attrs ->
  case source do
    :user -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
    :autonomous -> Conversations._unsafe_create_autonomous_turn(attrs, sandbox.id)
  end
end

outcomes = for source <- [:user, :autonomous], _ <- 1..20 do
  {sandbox, _conv, attrs} = fixture.()
  [park, admission] = DeadlineRace.concurrently([
    fn -> SandboxTransitions._unsafe_submit(sandbox, "park") end,
    fn -> admit.(source, sandbox, attrs) end
  ])
  case {park, admission} do
    {{:ok, _}, {:error, :sandbox_not_ready}} -> {source, :park_first}
    {{:error, :sandbox_mid_turn}, {:ok, _}} -> {source, :admission_first}
    other -> raise "Invalid park/admission outcome: #{inspect(other)}"
  end
end

# Exercise both lock orders deterministically as well as scheduler-selected races.
owner = self()
for source <- [:user, :autonomous], first <- [:park, :admission] do
  {sandbox, _conv, attrs} = fixture.()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox.id)])
      result = if first == :park, do: SandboxTransitions._unsafe_submit(sandbox, "park"), else: admit.(source, sandbox, attrs)
      send(owner, {:held, self()})
      receive do
        :release -> result
      after
        5_000 -> raise "Lock release timeout"
      end
    end)
  end)
  receive do
    {:held, pid} when pid == holder.pid -> :ok
  after
    5_000 -> raise "Lock acquisition timeout"
  end
  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:backend, self(), backend})
      if first == :park, do: admit.(source, sandbox, attrs), else: SandboxTransitions._unsafe_submit(sandbox, "park")
    end)
  end)
  backend = receive do
    {:backend, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "Checkout timeout"
  end
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  send(holder.pid, :release)
  {:ok, {:ok, _}} = Task.await(holder)
  expected = if first == :park, do: :sandbox_not_ready, else: :sandbox_mid_turn
  {:error, ^expected} = Task.await(waiter)
end

for _ <- 1..20 do
  {sandbox, _conv, _attrs} = fixture.()
  results = DeadlineRace.concurrently([
    fn -> SandboxTransitions._unsafe_submit(sandbox, "park") end,
    fn -> SandboxTransitions._unsafe_submit(sandbox, "park") end
  ])
  1 = Enum.count(results, &match?({:ok, _}, &1))
  1 = Enum.count(results, &match?({:error, :sandbox_not_ready}, &1))
end

for _ <- 1..20 do
  {sandbox, _conv, _attrs} = fixture.()
  {:ok, park} = SandboxTransitions._unsafe_submit(sandbox, "park")
  {:ok, parked} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
  [resume, destroy] = DeadlineRace.concurrently([
    fn -> SandboxTransitions._unsafe_submit(parked, "resume") end,
    fn -> SandboxOperations._unsafe_submit_destroy(parked) end
  ])
  case {resume, destroy} do
    {{:ok, _}, {:error, :provider_operation_fenced}} -> :ok
    {{:error, :sandbox_not_ready}, {:ok, _}} -> :ok
    other -> raise "Invalid resume/destroy outcome: #{inspect(other)}"
  end
end

IO.puts("SANDBOX_TRANSITION_RACE_RESULT=" <> Jason.encode!(%{
  park_admission_races: 40, deterministic_lock_orders: 4,
  duplicate_park_races: 20, resume_destroy_races: 20,
  outcomes: Enum.frequencies_by(outcomes, fn {source, outcome} -> "#{source}:#{outcome}" end),
  separate_database_connections: true, live_provider_operations: 0
}))
