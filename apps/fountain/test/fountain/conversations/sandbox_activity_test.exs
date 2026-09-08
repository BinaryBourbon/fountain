defmodule Fountain.Conversations.SandboxActivityTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{LogEvent, SandboxOperation, SandboxOperations, SandboxTransitions}

  setup do
    keys = [:sandbox_idle_timeout_minutes, :sandbox_max_lifetime_hours]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:fountain, &1)})
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 60)
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 0)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:fountain, key, old)
          :error -> Application.delete_env(:fountain, key)
        end
      end
    end)

    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "pending")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, conv)

    {:ok, _} =
      SandboxOperations._unsafe_complete_create(
        creation.id,
        {:ok,
         %Managoat.Sandbox.Handle{
           provider: :sprites,
           name: sandbox.sprite_name,
           instance_id: Ecto.UUID.generate()
         }}
      )

    {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, conv)
    %{sandbox: age_sandbox_activity(sandbox), conv: Repo.reload!(conv), user: user}
  end

  test "a long turn that just finished keeps the machine active", c do
    turn = insert_turn(c.conv, status: "completed")
    old = c.sandbox.inserted_at

    turn
    |> Ecto.Changeset.change(
      inserted_at: old,
      started_at: old,
      ended_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update!()

    assert_refused(c.sandbox)
    assert {0, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
  end

  test "another holder's recent turn counts even after that holder ends", c do
    peer = insert_conversation(user_id: c.user.id, sandbox: c.sandbox, status: "terminated")
    age_sandbox_activity(c.sandbox)

    insert_turn(peer,
      status: "completed",
      ended_at: DateTime.truncate(DateTime.utc_now(), :second)
    )

    assert_refused(c.sandbox)
  end

  test "bookkeeping updates do not refresh activity", c do
    {:ok, _} = Conversations.update_conversation(c.conv, %{title: "bookkeeping"})

    {:ok, _} =
      Conversations.update_sandbox(c.sandbox, %{provider_meta: %{"note" => "bookkeeping"}})

    assert {:ok, _} = SandboxTransitions._unsafe_submit(c.sandbox, {:park, :idle})
  end

  test "attachment without a turn grants an idle grace period", c do
    assert {:ok, _} =
             Conversations.create_conversation(%{
               user_id: c.user.id,
               sandbox_id: c.sandbox.id,
               runtime: c.conv.runtime,
               status: "idle"
             })

    assert_refused(c.sandbox)
  end

  test "transfer of an old holder refreshes destination activity", c do
    source = insert_sandbox(user_id: c.user.id, status: "ready")
    peer = insert_conversation(user_id: c.user.id, sandbox: source, status: "idle")
    age_sandbox_activity(source)

    assert {:ok, _} =
             Conversations.update_conversation(Repo.reload!(peer), %{sandbox_id: c.sandbox.id})

    assert_refused(c.sandbox)
  end

  test "terminal holder revival is activity even without a binding change", c do
    {:ok, ended} = Conversations.update_conversation(c.conv, %{status: "terminated"})
    assert {:ok, _} = Conversations.update_conversation(ended, %{status: "idle"})
    assert_refused(c.sandbox)
  end

  test "disabled or extended policy refuses an earlier idle verdict", c do
    for minutes <- [nil, 0, 180] do
      Application.put_env(:fountain, :sandbox_idle_timeout_minutes, minutes)
      assert_refused(c.sandbox)
    end
  end

  test "a lifetime park requires the current continuous run to reach its bound", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    fresh = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, resumed} = Conversations.update_sandbox(c.sandbox, %{last_resumed_at: fresh})
    assert_refused(resumed, :max_lifetime)
    assert_refused(resumed, :idle)

    {:ok, old_run} =
      Conversations.update_sandbox(resumed, %{last_resumed_at: c.sandbox.inserted_at})

    assert_refused(old_run, :idle)
    assert {:ok, _} = SandboxTransitions._unsafe_submit(old_run, {:park, :max_lifetime})
  end

  test "a park grant cannot carry a stale reason after policy changes", c do
    Application.put_env(:fountain, :sandbox_max_lifetime_hours, 1)
    assert_refused(c.sandbox, :idle)
    assert {:ok, _} = SandboxTransitions._unsafe_submit(c.sandbox, {:park, :max_lifetime})
  end

  test "resuming an owned parked machine does not require idle policy", c do
    {:ok, park} = SandboxTransitions._unsafe_submit(c.sandbox, {:park, :idle})
    {:ok, parked} = SandboxTransitions._unsafe_complete(park.id, {:ok, :skipped}, :idle)
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 0)
    assert {:ok, _} = SandboxTransitions._unsafe_submit(parked, "resume")
  end

  defp assert_refused(sandbox, reason \\ :idle) do
    reject(Managoat.Sandbox, :suspend, 1)
    reject(Managoat.Sandbox, :create_checkpoint_once, 2)

    assert {:error, :lifecycle_bound_not_reached} =
             SandboxTransitions._unsafe_park(sandbox, reason)

    assert Repo.reload!(sandbox).status == "ready"

    refute Repo.exists?(
             from o in SandboxOperation, where: o.sandbox_id == ^sandbox.id and o.action == "park"
           )

    assert Repo.aggregate(LogEvent, :count) == 0
  end
end
