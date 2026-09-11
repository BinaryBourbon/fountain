defmodule Fountain.Workers.SandboxResetReconcilerTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Workers.SandboxResetReconciler

  setup do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, token: "test")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous),
        else: Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    end)

    :ok
  end

  defp pending_reset do
    sandbox = insert_sandbox(mode: "persistent", status: "ready")
    stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, {:unavailable, :timeout}} end)
    assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(sandbox)
    Repo.reload!(sandbox)
  end

  test "sweeps discover lost callers and keep one job through retry backoff" do
    sandbox = pending_reset()
    _live = insert_sandbox(mode: "persistent", status: "ready")
    assert :ok = perform_job(SandboxResetReconciler, %{})
    assert :ok = perform_job(SandboxResetReconciler, %{})
    assert [job] = all_enqueued(worker: SandboxResetReconciler)
    assert job.args == %{"sandbox_id" => sandbox.id}

    for state <- ["retryable", "suspended"] do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
      assert :ok = perform_job(SandboxResetReconciler, %{})
      assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 1
    end

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])
    assert :ok = perform_job(SandboxResetReconciler, %{})
    assert [_] = all_enqueued(worker: SandboxResetReconciler)
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 2
  end

  test "failed deletes retry with capacity held; confirmed deletion completes the job" do
    sandbox = pending_reset()

    assert {:error, :sandbox_reset_pending} =
             perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})

    assert Repo.reload!(sandbox).status == "ready"
    assert Fountain.Quotas.active_sandbox_count(sandbox.user_id) == 1

    expect(Managoat.Sandbox.Sprites, :destroy, fn h ->
      assert h.name == sandbox.sprite_name
      refute Repo.in_transaction?()
      :ok
    end)

    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})
    assert Repo.reload!(sandbox).status == "terminated"
    assert Fountain.Quotas.active_sandbox_count(sandbox.user_id) == 0
    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})

    assert [event] =
             Repo.all(
               from a in Fountain.Audit.Event,
                 where: a.resource_id == ^sandbox.id and a.action == "sandbox.reset"
             )

    assert event.actor == "system:sandbox_reset_reconciler"
  end

  test "disabled providers wait; stale jobs never delete an unfenced or missing machine" do
    sandbox = pending_reset()
    Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert {:snooze, 300} = perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})
    assert Repo.reload!(sandbox).status == "ready"

    live = insert_sandbox(mode: "persistent", status: "ready")
    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: live.id})
    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: Ecto.UUID.generate()})
  end
end
