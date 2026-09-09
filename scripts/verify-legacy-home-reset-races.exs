alias Fountain.{Conversations, Repo}

alias Fountain.Conversations.{
  Conversation,
  LegacyResume,
  Sandbox,
  SandboxOperation,
  Turn,
  WakeContext
}

import Ecto.Query
config = Repo.config()
url = URI.parse(config[:url] || "")
host = config[:hostname] || url.host
database = config[:database] || String.trim_leading(url.path || "", "/")

if Mix.env() != :test or host not in ["localhost", "127.0.0.1"] or
     not String.starts_with?(database, "fountain_deadline_races_"),
   do: raise("This proof requires a dedicated local fountain_deadline_races_* database")

Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

defmodule LegacyHomeResetRace do
  def concurrently(functions) do
    owner = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          Fountain.Repo.checkout(fn ->
            %{rows: [[backend]]} = Fountain.Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:ready, self(), backend})

            receive do
              :go -> fun.()
            after
              10_000 -> raise "Barrier timed out"
            end
          end)
        end)
      end)

    participants =
      Enum.map(tasks, fn task ->
        receive do
          {:ready, pid, backend} when pid == task.pid -> {pid, backend}
        after
          10_000 -> raise "Database checkout timed out"
        end
      end)

    if MapSet.size(MapSet.new(Enum.map(participants, &elem(&1, 1)))) != length(functions),
      do: raise("The race did not use independent database connections")

    Enum.each(participants, fn {pid, _} -> send(pid, :go) end)
    Enum.map(tasks, &Task.await(&1, 15_000))
  end
end

# Only this in-memory adapter is registered. No provider credentials or network.
defmodule LegacyHomeResetAdapter do
  def capabilities, do: MapSet.new([:destroy_once])
  def build_handle(name), do: %Managoat.Sandbox.Handle{provider: :sprites, name: name}

  def destroy_once(handle, _opts) do
    false = Fountain.Repo.in_transaction?()

    operation =
      Fountain.Repo.one!(
        from o in Fountain.Conversations.SandboxOperation,
          where: o.sandbox_name == ^handle.name and o.action == "destroy"
      )

    true = not is_nil(operation.delete_started_at)
    true = operation.holds_slot
    true = operation.provider_instance_id == handle.instance_id
    sandbox = Fountain.Repo.get!(Fountain.Conversations.Sandbox, operation.sandbox_id)
    "terminated" = sandbox.status
    nil = sandbox.terminated_at

    false =
      Fountain.Repo.exists?(
        from c in Fountain.Conversations.Conversation,
          where: c.sandbox_id == ^sandbox.id and not is_nil(c.runtime_session_id)
      )

    Agent.update(LegacyHomeResetCalls, &(&1 + 1))
    :ok
  end
end

{:ok, _} = Agent.start_link(fn -> 0 end, name: LegacyHomeResetCalls)
Application.put_env(:managoat_sandbox, :adapters, %{sprites: LegacyHomeResetAdapter})
Application.put_env(:fountain, :sandboxes, fleet_ceiling: 100, cap_ceiling: 100)

fixture = fn status ->
  user =
    Repo.insert!(%Fountain.Accounts.User{
      email: "reset-proof-#{Ecto.UUID.generate()}@example.test",
      comped: true
    })

  sandbox =
    Repo.insert!(%Sandbox{
      user_id: user.id,
      sprite_name: "local-reset-#{Ecto.UUID.generate()}",
      provider_instance_id: Ecto.UUID.generate(),
      status: status,
      mode: "persistent"
    })

  parent =
    Repo.insert!(%Conversation{
      user_id: user.id,
      sandbox_id: sandbox.id,
      runtime: "claude",
      status: "idle",
      runtime_session_id: "old-session"
    })

  {sandbox, parent}
end

outcomes =
  for source <- [:user, :autonomous], _ <- 1..20 do
    {sandbox, parent} = fixture.("ready")

    attrs = %{
      conversation_id: parent.id,
      turn_number: 1,
      prompt: "local proof",
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    admit = fn ->
      case source do
        :user -> Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
        :autonomous -> Conversations._unsafe_create_autonomous_turn(attrs, sandbox.id)
      end
    end

    case LegacyHomeResetRace.concurrently([fn -> Conversations.reset_sandbox(sandbox) end, admit]) do
      [{:ok, _}, {:error, :sandbox_not_ready}] ->
        "terminated" = Repo.reload!(sandbox).status
        true = not is_nil(Repo.reload!(sandbox).terminated_at)
        nil = Repo.reload!(parent).runtime_session_id
        false = Repo.exists?(from t in Turn, where: t.conversation_id == ^parent.id)
        operation = Repo.one!(from o in SandboxOperation, where: o.sandbox_id == ^sandbox.id)
        "confirmed" = operation.state
        false = operation.holds_slot
        :reset_first

      [{:error, :sandbox_mid_turn}, {:ok, turn}] ->
        "ready" = Repo.reload!(sandbox).status
        "running" = Repo.reload!(turn).status
        "old-session" = Repo.reload!(parent).runtime_session_id
        false = Repo.exists?(from o in SandboxOperation, where: o.sandbox_id == ^sandbox.id)
        :admission_first

      other ->
        raise "Reset/admission was not exclusive: #{inspect(other)}"
    end
  end

resumes =
  for _ <- 1..20 do
    {sandbox, parent} = fixture.("suspended")
    {:ok, context} = WakeContext.new(parent, nil)

    case LegacyHomeResetRace.concurrently([
           fn -> Conversations.reset_sandbox(sandbox) end,
           fn -> LegacyResume.submit(context, sandbox) end
         ]) do
      [{:ok, _}, {:error, :ownership_changed}] ->
        "terminated" = Repo.reload!(sandbox).status
        nil = Repo.reload!(parent).runtime_session_id
        :reset_first

      [{:error, :provider_operation_fenced}, {:ok, operation}] ->
        "resume" = operation.action
        "suspended" = Repo.reload!(sandbox).status
        "old-session" = Repo.reload!(parent).runtime_session_id
        true = operation.holds_slot
        :resume_first

      other ->
        raise "Reset/resume was not exclusive: #{inspect(other)}"
    end

    1 = Repo.aggregate(from(o in SandboxOperation, where: o.sandbox_id == ^sandbox.id), :count)
  end

IO.puts(
  "LEGACY_HOME_RESET_RACE_RESULT=" <>
    Jason.encode!(%{
      reset_user_admission_races: 20,
      reset_autonomous_admission_races: 20,
      reset_resume_races: 20,
      independent_connections_per_race: 2,
      admission_outcomes: Enum.frequencies(outcomes),
      reset_resume_exclusive: length(resumes) == 20,
      grant_and_session_reset_committed_before_io: true,
      original_instance_preserved: true,
      fake_adapter_calls: Agent.get(LegacyHomeResetCalls, & &1),
      live_provider_calls: 0,
      scope:
        "Local PostgreSQL and in-memory adapter; no live provider or account/reaper/park integration proof"
    })
)
