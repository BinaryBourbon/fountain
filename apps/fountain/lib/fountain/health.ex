defmodule Fountain.Health do
  @moduledoc """
  Dependency checks behind the readiness probe.

  The rule for what belongs here: a check earns its place only if a failure
  means this pod should stop receiving traffic. That is a higher bar than "is
  something wrong".

  * **Postgres** qualifies. Essentially every request touches it, so a pod that
    cannot reach it can serve nothing useful.

  * **Sprites does not.** An invalid or expired `SPRITES_TOKEN` breaks
    conversations while sign-in, the dashboard, agent and environment
    management all keep working. Failing readiness on it would take the whole
    site down over a degraded feature — and it would put a third party's uptime
    on our serving path, so their outage would become ours. It belongs in
    alerting, not in a probe.

  * **Migrations do not**, because they cannot fail here. `Ecto.Migrator` is a
    supervised child that runs before `FountainWeb.Endpoint` starts
    (`Fountain.Application`), so a pod that failed its migrations has no
    listening socket to probe — it crashes and restarts instead. A pending
    migration check would be code that can never fire.
  """

  require Logger

  # A healthy check is ~2ms. These bound the unhealthy one as far as they can:
  # `:timeout` covers the query once a connection is in hand, and the queue
  # options cap how long we wait for the pool to produce one.
  #
  # They do not make the check fast when Postgres is unreachable. Measured
  # against a stopped Postgres, the endpoint answers 503 in ~2.9s: the connect
  # attempt and DBConnection's own retry are not per-call options, so some of
  # that wait is not ours to cap. The probe's `timeoutSeconds` (see
  # k8s/deployment.yaml) is the outer bound, set above that figure so kubelet
  # reads the explicit 503 rather than timing the request out — both score a
  # failure, but only one of them shows up as a real response.
  @check_opts [timeout: 2_000, queue_target: 200, queue_interval: 300]

  @doc """
  Round-trips a trivial query to Postgres.

  Returns `:ok` or `:error` — never a reason. The readiness endpoint is public
  (Traefik routes the whole host), so nothing here should describe our
  internals to an anonymous caller. The reason is logged instead.
  """
  @spec database(module()) :: :ok | :error
  def database(repo \\ Fountain.Repo) do
    case Ecto.Adapters.SQL.query(repo, "SELECT 1", [], @check_opts) do
      {:ok, _result} -> :ok
      {:error, reason} -> unhealthy(reason)
    end
  rescue
    # DBConnection raises when there is no connection to hand out at all.
    e -> unhealthy(e)
  catch
    # A pool checkout that gives up exits rather than returning.
    :exit, reason -> unhealthy(reason)
  end

  defp unhealthy(reason) do
    Logger.warning("readiness: database check failed: #{inspect(reason)}")
    :error
  end
end
