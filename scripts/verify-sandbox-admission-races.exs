# The prelude refuses non-test/non-local databases and checks independent connections.
Code.require_file("scripts/verify-turn-deadline-races.exs")
alias Fountain.{Conversations, Repo}
alias Fountain.Conversations.{Conversation, Sandbox, SandboxIdentity, Turn}

{:ok, _} = Application.ensure_all_started(:mimic)
:ok = Mimic.copy(Managoat.Sandbox)
:ok = Mimic.set_mimic_global()
# Exercise the real reset context; only its outbound deletion is synthetic.
Mimic.stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

fixture = fn ->
  user =
    Repo.insert!(%Fountain.Accounts.User{
      email: "sandbox-race-#{Ecto.UUID.generate()}@example.test"
    })

  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-sandbox-#{Ecto.UUID.generate()}",
      mode: "persistent",
      status: "ready"
    })

  conv =
    Repo.insert!(%Conversation{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "idle"
    })

  attrs = %{
    conversation_id: conv.id,
    turn_number: 1,
    prompt: "local sandbox race; no provider execution",
    status: "running",
    started_at: DateTime.utc_now() |> DateTime.truncate(:second)
  }

  {sandbox, conv, attrs}
end

admissions =
  for source <- [:user, :autonomous], _ <- 1..20 do
    {sandbox, conv, attrs} = fixture.()

    admit = fn ->
      case source do
        :user -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
        :autonomous -> Conversations._unsafe_create_autonomous_turn(attrs)
      end
    end

    [reset, admission] =
      DeadlineRace.concurrently([
        fn -> Conversations.reset_sandbox(sandbox, actor: "system:sandbox_race") end,
        admit
      ])

    case {reset, admission} do
      {{:ok, _}, {:error, :sandbox_not_ready}} ->
        "terminated" = Repo.get!(Sandbox, sandbox.id).status
        "idle" = Repo.get!(Conversation, conv.id).status
        [] = Conversations._unsafe_list_turns(conv.id)
        {source, :reset_first}

      {{:error, :sandbox_mid_turn}, {:ok, turn}} ->
        "ready" = Repo.get!(Sandbox, sandbox.id).status
        "running" = Repo.get!(Turn, turn.id).status
        "running" = Repo.get!(Conversation, conv.id).status
        {source, :admission_first}

      other ->
        raise "Nonexclusive reset/admission results: #{inspect(other)}"
    end
  end

owner = self()

start_on_connection = fn fun ->
  task =
    Task.async(fn ->
      Repo.checkout(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)

  backend =
    receive do
      {:backend, pid, backend} when pid == task.pid -> backend
    after
      5_000 -> raise "Database checkout timed out"
    end

  {task, backend}
end

wait_for_lock = fn backend ->
  waiting =
    Enum.reduce_while(1..200, false, fn _, _ ->
      case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
        [["Lock"]] ->
          {:halt, true}

        _ ->
          Process.sleep(5)
          {:cont, false}
      end
    end)

  true = waiting
end

for source <- [:user, :autonomous], first <- [:reset, :admission] do
  {sandbox, conv, attrs} = fixture.()

  admit = fn ->
    case source do
      :user -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
      :autonomous -> Conversations._unsafe_create_autonomous_turn(attrs)
    end
  end

  holder =
    Task.async(fn ->
      Repo.transaction(fn ->
        case first do
          :reset ->
            Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox.id)])

          :admission ->
            Repo.query!("SELECT id FROM conversations WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(conv.id)
            ])
        end

        send(owner, {:held, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "Lock release timed out"
        end

        if first == :reset,
          do: sandbox |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()
      end)
    end)

  receive do
    {:held, pid} when pid == holder.pid -> :ok
  after
    5_000 -> raise "Lock acquisition timed out"
  end

  {admission, backend} = start_on_connection.(admit)
  wait_for_lock.(backend)

  case first do
    :reset ->
      send(holder.pid, :release)
      {:ok, _} = Task.await(holder)
      {:error, :sandbox_not_ready} = Task.await(admission)
      [] = Conversations._unsafe_list_turns(conv.id)

    :admission ->
      {reset, reset_backend} =
        start_on_connection.(fn -> Conversations.reset_sandbox(sandbox) end)

      # Admission holds the machine lock while waiting for its parent row.
      # Reset must wait for admission, even before that turn has been inserted.
      wait_for_lock.(reset_backend)
      send(holder.pid, :release)
      {:ok, _} = Task.await(holder)
      {:ok, turn} = Task.await(admission)
      {:error, :sandbox_mid_turn} = Task.await(reset)
      "running" = Repo.get!(Turn, turn.id).status
      "ready" = Repo.get!(Sandbox, sandbox.id).status
  end
end

for _ <- 1..20 do
  {sandbox, _, _} = fixture.()
  first = Ecto.UUID.generate()
  second = Ecto.UUID.generate()

  results =
    DeadlineRace.concurrently([
      fn -> SandboxIdentity._unsafe_bind(sandbox, first) end,
      fn -> SandboxIdentity._unsafe_bind(sandbox, second) end
    ])

  [{:ok, bound}] = Enum.filter(results, &match?({:ok, _}, &1))
  [{:error, :provider_identity_changed}] = Enum.filter(results, &match?({:error, _}, &1))
  true = Repo.get!(Sandbox, sandbox.id).provider_instance_id == bound.provider_instance_id
end

# Late status writers and retirement race on independent connections. Once
# retirement commits, a stale ready callback must lose, whichever started first.
for retired <- ["terminated", "failed"], _ <- 1..20 do
  {sandbox, _, _} = fixture.()

  [retirement, late_ready] =
    DeadlineRace.concurrently([
      fn -> Conversations.update_sandbox(sandbox, %{status: retired}) end,
      fn -> Conversations.update_sandbox(sandbox, %{status: "ready"}) end
    ])

  {:ok, _} = retirement
  true = Repo.get!(Sandbox, sandbox.id).status == retired

  case late_ready do
    {:ok, _} -> :ok
    {:error, %Ecto.Changeset{errors: [status: {"sandbox is retired", []}]}} -> :ok
    other -> raise "Unexpected late ready result: #{inspect(other)}"
  end
end

# Force the stale callback to wait on the retirement writer's row lock.
for retired <- ["terminated", "failed"] do
  {sandbox, _, _} = fixture.()

  holder =
    Task.async(fn ->
      Repo.transaction(fn ->
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: retired})
        send(owner, {:retirement_held, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "Retirement lock release timed out"
        end
      end)
    end)

  receive do
    {:retirement_held, pid} when pid == holder.pid -> :ok
  after
    5_000 -> raise "Retirement lock acquisition timed out"
  end

  {late_ready, backend} =
    start_on_connection.(fn -> Conversations.update_sandbox(sandbox, %{status: "ready"}) end)

  wait_for_lock.(backend)
  send(holder.pid, :release)
  {:ok, :ok} = Task.await(holder)
  {:error, %Ecto.Changeset{}} = Task.await(late_ready)
  true = Repo.get!(Sandbox, sandbox.id).status == retired
end

IO.puts(
  "SANDBOX_ADMISSION_RACE_RESULT=" <>
    Jason.encode!(%{
      admission_cases: length(admissions),
      outcomes: admissions |> Enum.map(fn {a, b} -> "#{a}:#{b}" end) |> Enum.frequencies(),
      conflicting_identity_cases: 20,
      retirement_ready_cases: 40,
      forced_retirement_before_ready_cases: 2,
      forced_reset_and_admission_orderings: 4,
      separate_database_connections: true,
      provider_operations: 0,
      scope:
        "Local reset/admission and identity arbitration; deletion acknowledgments are synthetic"
    })
)
