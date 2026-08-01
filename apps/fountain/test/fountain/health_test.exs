defmodule Fountain.HealthTest do
  @moduledoc """
  The dependency check behind the readiness probe.

  The failure paths use a repo pointed at a port nothing listens on, rather than
  a mock, because the thing worth proving is that a real connection failure
  comes back as `:error` instead of escaping as an exception — a raise here
  would render a 500 from the probe endpoint, which reads as "broken app" rather
  than "not ready".
  """

  use Fountain.DataCase, async: true

  import ExUnit.CaptureLog

  alias Fountain.Health

  defmodule DeadRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :fountain, adapter: Ecto.Adapters.Postgres
  end

  defmodule UnstartedRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :fountain, adapter: Ecto.Adapters.Postgres
  end

  describe "database/1" do
    test "returns :ok when Postgres answers" do
      assert Health.database() == :ok
    end

    test "returns :error when nothing is listening" do
      # The repo is linked to this process and its connection will keep failing,
      # so an exit must not take the test with it.
      Process.flag(:trap_exit, true)

      # Port 1 is privileged and unused; the connect fails immediately.
      {:ok, pid} =
        DeadRepo.start_link(
          hostname: "127.0.0.1",
          port: 1,
          username: "nobody",
          password: "nobody",
          database: "nothing",
          pool_size: 1,
          log: false
        )

      log =
        capture_log(fn ->
          assert Health.database(DeadRepo) == :error
        end)

      assert log =~ "readiness: database check failed"

      Supervisor.stop(pid)
    end

    test "returns :error when the repo is not running at all" do
      # What a probe hits during boot, before the Repo child has started.
      log =
        capture_log(fn ->
          assert Health.database(UnstartedRepo) == :error
        end)

      assert log =~ "readiness: database check failed"
    end

    test "the failure reason never leaves the module" do
      # The readiness endpoint is public, so the check returns a bare atom and
      # logs the detail. This pins that contract.
      log =
        capture_log(fn ->
          assert Health.database(UnstartedRepo) in [:ok, :error]
        end)

      assert log =~ "readiness:"
    end
  end
end
