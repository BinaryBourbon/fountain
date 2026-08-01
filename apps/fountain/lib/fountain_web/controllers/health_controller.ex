defmodule FountainWeb.HealthController do
  @moduledoc """
  Two endpoints, because a probe that restarts a pod and a probe that removes it
  from the load balancer want opposite things.

  `/health` is liveness: static, no dependencies. If it checked the database, a
  Postgres blip would restart every pod at once — and restarting an app does
  nothing to fix a database.

  `/health/ready` is readiness: it fails while this pod cannot serve, and
  kubelet takes it out of rotation without killing it. Recovery needs no
  restart; the next probe passes and traffic returns.

  Both probes pointed at `/health` until #163, so a pod with an unreachable
  database stayed Ready and kept taking traffic it could not serve.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias FountainWeb.Schemas

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Health"])
  security([])

  operation(:show,
    summary: "Liveness probe",
    description:
      ~s|Public, unauthenticated. Returns `{"status": "ok"}` if the app is up. | <>
        "Checks no dependencies by design — ask `/health/ready` whether this " <>
        "instance can actually serve.",
    responses: [
      ok: {"Health response", "application/json", Schemas.HealthResponse}
    ]
  )

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end

  operation(:ready,
    summary: "Readiness probe",
    description:
      "Public, unauthenticated. Returns 200 when this instance can serve requests, " <>
        "or 503 when a dependency it cannot work without is unavailable. Individual " <>
        "checks report `ok` or `error` and nothing further.",
    responses: [
      ok: {"Ready", "application/json", Schemas.ReadinessResponse},
      service_unavailable: {"Not ready", "application/json", Schemas.ReadinessResponse}
    ]
  )

  def ready(conn, _params) do
    checks = %{"database" => Fountain.Health.database()}
    ready? = Enum.all?(checks, fn {_name, result} -> result == :ok end)

    conn
    |> put_status(if ready?, do: :ok, else: :service_unavailable)
    |> json(%{
      status: if(ready?, do: "ok", else: "error"),
      checks: Map.new(checks, fn {name, result} -> {name, to_string(result)} end)
    })
  end
end
