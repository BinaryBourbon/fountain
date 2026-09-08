# Enforce max-lifetime deletion against current policy, mode and admission after real lock waits.
# Completion and attachment reset idle activity, not the continuous-run lifetime clock.
Code.require_file("scripts/verify-sandbox-idle-races.exs")

alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Sandbox, SandboxOperations, Turn}

fixture = fn ->
  user = Repo.insert!(%Fountain.Accounts.User{email: "destroy-bound-#{Ecto.UUID.generate()}@example.test"})
  sandbox = Repo.insert!(%Sandbox{user_id: user.id, sprite_name: "local-destroy-bound-#{Ecto.UUID.generate()}", status: "pending"})
  {:ok, conv} = Conversations.create_conversation(%{user_id: user.id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
  {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)
  {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, %Managoat.Sandbox.Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: Ecto.UUID.generate()}})
  {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
  {Fountain.Factory.age_sandbox_activity(sandbox), conv}
end

keys = [:sandbox_idle_timeout_minutes, :sandbox_max_lifetime_hours]
previous = Enum.map(keys, &{&1, Application.fetch_env(:fountain, &1)})

try do
  for scenario <- [:disabled, :extended, :tightened, :completion, :attachment, :wake, :home, :admission] do
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 60)
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, if(scenario == :tightened, do: 3, else: 1))
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
          :disabled -> Application.put_env(:fountain, :sandbox_max_lifetime_hours, 0)
          :extended -> Application.put_env(:fountain, :sandbox_max_lifetime_hours, 3)
          :tightened -> Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
          :completion -> turn |> Ecto.Changeset.change(status: "completed", ended_at: DateTime.truncate(DateTime.utc_now(), :second)) |> Repo.update!()
          :attachment -> {:ok, _} = Conversations.create_conversation(%{user_id: conv.user_id, sandbox_id: sandbox.id, runtime: "claude", status: "idle"})
          :home -> {:ok, _} = Conversations.update_sandbox(sandbox, %{mode: "persistent"})
          :admission -> {:ok, _} = Conversations._unsafe_create_turn_on_sandbox(%{conversation_id: conv.id, turn_number: 1, prompt: "new work", status: "running"}, sandbox.id, :unbounded)
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
        SandboxOperations._unsafe_submit_destroy_at_bound(sandbox, :max_lifetime)
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
    if scenario in [:tightened, :completion, :attachment] do
      {:ok, operation} = result
      true = DateTime.compare(operation.submitted_at, changed_at) != :lt
    else
      expected = case scenario do
        :home -> :lifecycle_action_changed
        :admission -> :sandbox_mid_turn
        _ -> :lifecycle_bound_not_reached
      end
      {:error, ^expected} = result
      "ready" = Repo.reload!(sandbox).status
      nil = Repo.get_by(Fountain.Conversations.SandboxOperation, sandbox_id: sandbox.id, action: "destroy")
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

IO.puts("SANDBOX_DESTROY_BOUND_RACE_RESULT=" <> Jason.encode!(%{
  forced_lock_wait_cases: 8,
  cases: ~w(disabled extended tightened completion attachment wake home admission),
  separate_database_connections: true, observed_postgres_lock_waits: true,
  clock_sampled_after_lock: true, live_provider_operations: 0
}))
