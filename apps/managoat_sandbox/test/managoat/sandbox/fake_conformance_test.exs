defmodule Managoat.Sandbox.FakeConformanceTest do
  # The Fake adapter passing the shared conformance suite is what proves the
  # suite is contract-shaped rather than Sprites-shaped — and the Fake's
  # frames come from real processes, so the owner-message contract is
  # exercised for real rather than hand-crafted.
  use Managoat.Sandbox.ConformanceCase,
    adapter: Managoat.Sandbox.Fake,
    fixtures: %{
      exec_ok: {"emit", ["out:hello"], "hello"},
      exec_fail: {"emit", ["out:oops", "exit:3"], 3},
      spawn_ok: {"emit", ["out:hello", "exit:0"]},
      spawn_drop: {"emit", ["out:partial", "drop"]},
      spawn_stay: {"emit", ["out:ready", "stay"]}
    }

  setup do
    Managoat.Sandbox.Fake.reset()
    :ok
  end

  # Fake-specific extras that the shared suite cannot assert generically.

  test "the applied policy is recorded verbatim — allow: [] reaches the backend" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("policy-check", [])

    :ok =
      Managoat.Sandbox.Fake.apply_network_policy(handle, %Managoat.Sandbox.NetworkPolicy{
        allow: []
      })

    assert %Managoat.Sandbox.NetworkPolicy{allow: []} =
             Managoat.Sandbox.Fake.policy("policy-check")
  end

  test "write_file stores contents the sandbox can read back" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("fs-check", [])
    :ok = Managoat.Sandbox.Fake.write_file(handle, "/home/sprite/.env", "A=1\n", mode: 0o600)
    assert Managoat.Sandbox.Fake.file("fs-check", "/home/sprite/.env") == "A=1\n"
  end
end
