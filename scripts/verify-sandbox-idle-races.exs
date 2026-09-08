# Rerun the holder/transition proofs with the activity clock, on independent connections.
Code.require_file("scripts/verify-sandbox-holder-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Sandbox, SandboxOperations, SandboxTransitions, Turn}

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "idle-#{Ecto.UUID.generate()}@example.test"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-idle-#{Ecto.UUID.generate()}", status: "pending"})
  {:ok, conv} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
  {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)
  {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, %Managoat.Sandbox.Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: Ecto.UUID.generate()}})
  {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
  {Fountain.Factory.age_sandbox_activity(sandbox), conv}
end

keys = [:sandbox_idle_timeout_minutes, :sandbox_max_lifetime_hours]
previous = Enum.map(keys, &{&1, Application.fetch_env(:fountain, &1)})

try do
  for scenario <- [:disabled, :extended, :tightened, :completion, :attachment, :wake] do
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, if(scenario == :tightened, do: 180, else: 60))
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 0)
    {sandbox, conv} = fixture.()
    turn = if scenario == :completion do
      Repo.insert!(%Turn{conversation_id: conv.id, turn_number: 1, prompt: "local idle race", status: "running", inserted_at: sandbox.inserted_at, started_at: sandbox.inserted_at})
    end
    owner = self()
    holder = Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox.id)])
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:holder, self(), backend})
        receive do
          :change -> :ok
        after
          5_000 -> raise "Holder release timeout"
        end
        case scenario do
          :disabled -> Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 0)
          :extended -> Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 180)
          :tightened -> Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 60)
          :completion -> turn |> Ecto.Changeset.change(status: "completed", ended_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update!()
          :attachment -> {:ok, _} = Conversations.create_conversation(%{user_id: conv.user_id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
          :wake -> {:ok, _} = Conversations.update_sandbox(sandbox, %{last_resumed_at: DateTime.truncate(DateTime.utc_now(), :second)})
        end
        DateTime.utc_now()
      end)
    end)
    holder_backend = receive do
      {:holder, pid, backend} when pid == holder.pid -> backend
    after
      5_000 -> raise "Holder checkout timeout"
    end
    waiter = Task.async(fn ->
      Repo.checkout(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:waiter, self(), backend})
        SandboxTransitions._unsafe_submit(sandbox, {:park, :idle})
      end)
    end)
    waiter_backend = receive do
      {:waiter, pid, backend} when pid == waiter.pid -> backend
    after
      5_000 -> raise "Waiter checkout timeout"
    end
    true = holder_backend != waiter_backend
    true = Enum.reduce_while(1..200, false, fn _, _ ->
      case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [waiter_backend]).rows do
        [["Lock"]] -> {:halt, true}
        _ -> Process.sleep(5); {:cont, false}
      end
    end)
    send(holder.pid, :change)
    {:ok, changed_at} = Task.await(holder, 10_000)
    result = Task.await(waiter, 10_000)
    if scenario == :tightened do
      {:ok, operation} = result
      true = DateTime.compare(operation.submitted_at, changed_at) != :lt
    else
      {:error, :lifecycle_bound_not_reached} = result
      "ready" = Repo.reload!(sandbox).status
      false = SandboxTransitions._unsafe_pending?(sandbox.id)
    end
  end

after
  for {key, value} <- previous do
    case value do
      {:ok, old} -> Application.put_env(:fountain, key, old)
      :error -> Application.delete_env(:fountain, key)
    end
  end
end

IO.puts("SANDBOX_IDLE_RACE_RESULT=" <> Jason.encode!(%{
  forced_lock_wait_cases: 6,
  cases: ~w(disabled extended tightened completion attachment wake),
  separate_database_connections: true, observed_postgres_lock_waits: true,
  clock_sampled_after_lock: true, live_provider_operations: 0
}))
