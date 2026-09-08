# The prelude requires a dedicated local/test DB and independent backend PIDs.
Code.require_file("scripts/verify-sandbox-admission-races.exs")
Code.require_file("scripts/verify-sandbox-transition-races.exs")

require Ecto.Query
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Sandbox, SandboxHolders, SandboxOperations, SandboxTransitions}
alias Managoat.Sandbox.Handle

fixture = fn user ->
  user = user || Repo.insert!(%Fountain.Accounts.User{email: "holder-#{Ecto.UUID.generate()}@example.test"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-holder-#{Ecto.UUID.generate()}", status: "pending"})
  attrs = %{sandbox_id: sandbox.id, user_id: user.id, runtime: "claude", status: "idle"}
  {:ok, conv} = Conversations.create_conversation(attrs)
  {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)
  {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, %Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: Ecto.UUID.generate()}})
  {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
  {user, sandbox, conv, attrs}
end

# Holding the real machine lock forces both orderings, rather than relying on
# scheduler luck. The second participant is observed waiting in PostgreSQL.
forced = fn sandbox, first, second ->
  owner = self()
  holder = Task.async(fn ->
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox.id)])
      result = first.()
      send(owner, {:held, self()})
      receive do
        :release -> result
      after
        5_000 -> raise "Release timeout"
      end
    end)
  end)
  receive do
    {:held, pid} when pid == holder.pid -> :ok
  after
    5_000 -> raise "Holder timeout"
  end
  waiter = Task.async(fn ->
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(owner, {:backend, self(), backend})
      second.()
    end)
  end)
  backend = receive do
    {:backend, pid, backend} when pid == waiter.pid -> backend
  after
    5_000 -> raise "Waiter checkout timeout"
  end
  true = Enum.reduce_while(1..200, false, fn _, _ ->
    case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
      [["Lock"]] -> {:halt, true}
      _ -> Process.sleep(5); {:cont, false}
    end
  end)
  send(holder.pid, :release)
  {:ok, first_result} = Task.await(holder, 10_000)
  [first_result, Task.await(waiter, 10_000)]
end

race = fn sandbox, first, second, order ->
  case order do
    :race -> DeadlineRace.concurrently([first, second])
    :first -> forced.(sandbox, first, second)
    :second -> Enum.reverse(forced.(sandbox, second, first))
  end
end
orders = List.duplicate(:race, 20) ++ [:first, :second]

cleanup_results = for order <- orders do
  {_user, sandbox, conv, attrs} = fixture.(nil)
  conv |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()
  [attach, cleanup] = race.(sandbox,
    fn -> Conversations.create_conversation(attrs) end,
    fn -> SandboxOperations._unsafe_submit_destroy(sandbox, recovery: true) end, order)
  case {attach, cleanup} do
    {{:ok, _}, {:error, :sandbox_held}} -> :attachment_won
    {{:error, :provider_operation_fenced}, {:ok, _}} -> :cleanup_won
    other -> raise "Invalid attachment/cleanup outcome: #{inspect(other)}"
  end
end

park_results = for order <- orders do
  {_user, sandbox, _conv, attrs} = fixture.(nil)
  [attach, park] = race.(sandbox,
    fn -> Conversations.create_conversation(attrs) end,
    fn -> SandboxTransitions._unsafe_submit(sandbox, "park") end, order)
  case {attach, park} do
    {{:ok, holder}, {:ok, operation}} ->
      {:ok, _} = SandboxTransitions._unsafe_complete(operation.id, {:ok, :skipped}, :idle)
      true = Repo.exists?(Ecto.Query.from e in Fountain.Conversations.LogEvent, where: e.conversation_id == ^holder.id and e.stage == "sandbox")
      :attachment_included
    {{:error, :provider_operation_fenced}, {:ok, _}} -> :park_won
    other -> raise "Invalid attachment/park outcome: #{inspect(other)}"
  end
end

transfer_results = for source <- [:user, :autonomous], order <- orders do
  {user, sandbox, conv, _attrs} = fixture.(nil)
  {_user, destination, _other, _attrs} = fixture.(user)
  attrs = %{conversation_id: conv.id, turn_number: 1, prompt: "local holder race", status: "running", started_at: DateTime.utc_now()}
  admit = fn ->
    case source do
      :user -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
      :autonomous -> Conversations._unsafe_create_autonomous_turn(attrs, sandbox.id)
    end
  end
  [transfer, admission] = race.(sandbox,
    fn -> Conversations.update_conversation(conv, %{sandbox_id: destination.id}) end, admit, order)
  case {transfer, admission} do
    {{:ok, _}, {:error, :ownership_changed}} -> {source, :transfer_won}
    {{:error, :sandbox_mid_turn}, {:ok, _}} -> {source, :admission_won}
    other -> raise "Invalid transfer/admission outcome: #{inspect(other)}"
  end
end

for _ <- 1..20 do
  {user, first, left, _attrs} = fixture.(nil)
  {_user, second, right, _attrs} = fixture.(user)
  [{:ok, _}, {:ok, _}] = DeadlineRace.concurrently([
    fn -> Conversations.update_conversation(left, %{sandbox_id: second.id}) end,
    fn -> Conversations.update_conversation(right, %{sandbox_id: first.id}) end
  ])
end

bulk_results = for order <- orders do
  {user, source, parent, attrs} = fixture.(nil)
  {:ok, sibling} = Conversations.create_conversation(attrs)
  {_user, destination, _other, _attrs} = fixture.(user)
  {_user, independent, _other, _attrs} = fixture.(user)
  {:ok, _} = Conversations.update_sandbox(source, %{status: "terminated"})
  [bulk, individual] = race.(source,
    fn -> SandboxHolders._unsafe_replace(parent, destination.id) end,
    fn -> Conversations.update_conversation(sibling, %{sandbox_id: independent.id}) end, order)
  case {bulk, individual} do
    {{:ok, _}, {:error, :ownership_changed}} ->
      true = Repo.reload!(sibling).sandbox_id == destination.id
      :bulk_won
    {{:ok, _}, {:ok, _}} ->
      true = Repo.reload!(sibling).sandbox_id == independent.id
      true = Repo.reload!(parent).sandbox_id == destination.id
      :individual_preserved
    other -> raise "Invalid bulk/individual transfer outcome: #{inspect(other)}"
  end
end

IO.puts("SANDBOX_HOLDER_RACE_RESULT=" <> Jason.encode!(%{
  random_races: 120, forced_lock_orders: 10, reciprocal_transfers: 20,
  bulk_individual_transfer: Enum.frequencies(bulk_results),
  attachment_cleanup: Enum.frequencies(cleanup_results), attachment_park: Enum.frequencies(park_results),
  transfer_admission: Enum.frequencies_by(transfer_results, fn {source, winner} -> "#{source}:#{winner}" end),
  separate_database_connections: true, live_provider_operations: 0
}))
