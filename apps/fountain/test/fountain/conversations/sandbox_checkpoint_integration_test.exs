defmodule Fountain.Conversations.SandboxCheckpointIntegrationTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.{LogEvent, SandboxOperation, SandboxOperations, SandboxTransitions}
  alias Managoat.Sandbox.Handle

  setup do
    prior = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites)

    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites,
      checkpoint_creation_enabled: true
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, prior),
        else: Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    end)

    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "pending", mode: "persistent")
    parent = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    {:ok, creation} = SandboxOperations._unsafe_submit_create(sandbox, parent)

    handle = %Handle{
      provider: :sprites,
      name: sandbox.sprite_name,
      instance_id: "checkpoint-instance"
    }

    {:ok, _} = SandboxOperations._unsafe_complete_create(creation.id, {:ok, handle})
    {:ok, sandbox} = SandboxOperations._unsafe_finish_provision(sandbox, parent)
    %{sandbox: age_sandbox_activity(sandbox), creation: creation}
  end

  test "the released adapter carries the committed operation through POST and confirmation", c do
    owner = self()

    req =
      Req.new(
        base_url: "https://provider.invalid",
        plug: fn conn ->
          refute Repo.in_transaction?()
          operation = Repo.one!(from o in SandboxOperation, where: o.action == "park")
          assert operation.state == "submitted"
          send(owner, {:request, conn.method})
          assert conn.request_path =~ c.sandbox.sprite_name

          if conn.method == "POST" do
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["comment"] == "sandbox-operation:#{operation.id}"

            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!(%{type: "complete", data: "saved"}) <> "\n"
            )
          else
            Plug.Conn.send_resp(
              conn,
              200,
              Jason.encode!([
                %{id: "saved-checkpoint", comment: "sandbox-operation:#{operation.id}"}
              ])
            )
          end
        end
      )

    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)
    reject(Managoat.Sandbox, :create_checkpoint, 2)
    assert {:ok, parked} = SandboxTransitions._unsafe_park(c.sandbox, :idle)
    assert parked.provider_meta["checkpoint_id"] == "saved-checkpoint"
    assert_receive {:request, "POST"}
    assert_receive {:request, "GET"}
    refute_receive {:request, _}
    assert Repo.one!(from o in SandboxOperation, where: o.action == "park").state == "confirmed"
    assert Repo.aggregate(LogEvent, :count) == 1
    assert Repo.reload!(c.creation).holds_slot
  end

  test "an incomplete provider stream retains the host fence without confirmation or replay", c do
    owner = self()

    req =
      Req.new(
        base_url: "https://provider.invalid",
        plug: fn conn ->
          send(owner, {:request, conn.method})

          Plug.Conn.send_resp(
            conn,
            200,
            Jason.encode!(%{type: "info", data: "still working"}) <> "\n"
          )
        end
      )

    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)

    assert {:error, :provider_operation_uncertain} =
             SandboxTransitions._unsafe_park(c.sandbox, :idle)

    assert {:error, :provider_operation_fenced} =
             SandboxTransitions._unsafe_resume(Repo.reload!(c.sandbox))

    assert_receive {:request, "POST"}
    refute_receive {:request, _}
    assert Repo.one!(from o in SandboxOperation, where: o.action == "park").state == "uncertain"
    assert Repo.aggregate(LogEvent, :count) == 0
    assert Repo.reload!(c.creation).holds_slot
  end
end
