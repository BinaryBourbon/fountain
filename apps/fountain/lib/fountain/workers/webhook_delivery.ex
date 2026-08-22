defmodule Fountain.Workers.WebhookDelivery do
  @moduledoc """
  One HTTP POST of one event to one endpoint (#700).

  One job per (endpoint, event), so a slow receiver cannot stall a fast one,
  and its own queue so a webhook backlog never sits behind a maintenance
  sweep.

  `max_attempts: 8` with Oban's exponential backoff is roughly a day of
  retrying, which is the right order for "my receiver was deploying". Every
  attempt writes a `webhook_deliveries` row — that table is what powers the
  console's recent-deliveries view and the redeliver button.

  ## What this worker will not do

  - **Follow a redirect.** A `302` to `169.254.169.254` defeats every check in
    `Fountain.Webhooks.Url`, so a `3xx` is a delivery failure here, not a
    place to go next.
  - **Read an unbounded body.** The response is collected up to
    `Fountain.Webhooks.Delivery.max_body_bytes/0` and then the connection is
    dropped mid-stream.
  - **Resolve the host twice.** `Url.pin/1` resolves once, checks every
    answer, and hands back a URL addressing the checked IP; the hostname
    rides in the `Host` header and in TLS SNI. Without that the guard would
    have a rebinding window between our resolution and Finch's.
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 8

  alias Fountain.Webhooks
  alias Fountain.Webhooks.{Delivery, Endpoint, Signature, Url}

  @timeout_ms 10_000

  @doc "Enqueue one delivery. Returns the Oban job."
  @spec enqueue(String.t(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(endpoint_id, payload) when is_binary(endpoint_id) and is_map(payload) do
    %{"endpoint_id" => endpoint_id, "payload" => payload}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint_id" => id, "payload" => payload}} = job) do
    case Webhooks._unsafe_get_endpoint(id) do
      nil ->
        # Deleted while the job sat in the queue. Nothing to deliver to and
        # nothing to record against.
        :ok

      %Endpoint{status: "disabled"} ->
        # Switched off after this job was enqueued. Dropping it is the point
        # of switching it off.
        :ok

      endpoint ->
        deliver(endpoint, payload, job)
    end
  end

  defp deliver(endpoint, payload, job) do
    body = Jason.encode!(payload)
    event_id = Map.get(payload, "id", "")
    event_type = Map.get(payload, "type", "")

    started = System.monotonic_time(:millisecond)
    result = post(endpoint, body, event_id, event_type, job.attempt)
    duration = System.monotonic_time(:millisecond) - started

    {status_code, response_body, error} = unpack(result)

    Webhooks.record_delivery(%{
      webhook_endpoint_id: endpoint.id,
      event_id: event_id,
      event_type: event_type,
      attempt: job.attempt,
      status_code: status_code,
      duration_ms: duration,
      error: error,
      response_body: response_body,
      payload: payload
    })

    cond do
      is_integer(status_code) and status_code in 200..299 ->
        Webhooks.note_success(endpoint)
        :ok

      job.attempt >= job.max_attempts ->
        Webhooks.note_failure(endpoint, error || "HTTP #{status_code}")
        {:error, error || "HTTP #{status_code}"}

      true ->
        {:error, error || "HTTP #{status_code}"}
    end
  end

  defp unpack({:ok, %Req.Response{status: status, body: response_body}}) do
    error = if status in 200..299, do: nil, else: describe_status(status)
    {status, to_string(response_body), error}
  end

  defp unpack({:error, reason}), do: {nil, nil, describe_error(reason)}

  # Two shapes reach here, and dialyzer holds us to exactly those: a string
  # this module produced (an unreadable secret, a refused address) and the
  # `Exception.t()` Req returns on a transport failure.
  defp describe_error(reason) when is_binary(reason), do: reason

  defp describe_error(%{__exception__: true} = error), do: Exception.message(error)

  # A 3xx is not "nearly delivered" — it is a receiver asking us to make a
  # different request, which is the exact move the SSRF guard exists to
  # refuse.
  defp describe_status(status) when status in 300..399,
    do: "redirect (#{status}) — Fountain does not follow redirects"

  defp describe_status(status), do: "HTTP #{status}"

  defp post(endpoint, body, event_id, event_type, attempt) do
    with {:ok, secret} <- fetch_secret(endpoint),
         {:ok, pinned} <- Url.pin(endpoint.url) do
      timestamp = System.system_time(:second)

      headers = [
        {"content-type", "application/json"},
        {"host", host_header(endpoint.url, pinned.host)},
        {"user-agent", "Fountain-Webhooks/1"},
        {"fountain-signature", Signature.header(secret, body, timestamp)},
        {"fountain-event-id", event_id},
        {"fountain-event-type", event_type},
        {"fountain-delivery-attempt", to_string(attempt)}
      ]

      Req.post(req(pinned.host), url: pinned.url, headers: headers, body: body)
    end
  end

  defp fetch_secret(endpoint) do
    case Webhooks.secret(endpoint) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, "the signing secret could not be read"}
    end
  end

  # The port has to survive into the Host header; a receiver on :8443 that
  # gets a bare hostname will not match its own vhost.
  defp host_header(original_url, host) do
    case URI.parse(original_url) do
      %URI{port: port, scheme: scheme}
      when (scheme == "https" and port != 443) or (scheme == "http" and port != 80) ->
        "#{host}:#{port}"

      _ ->
        host
    end
  end

  defp req(hostname) do
    Req.new(
      [
        method: :post,
        receive_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms, hostname: hostname],
        # Ours, not Req's: an Oban retry writes a delivery row, a silent
        # in-process one does not.
        retry: false,
        redirect: false,
        decode_body: false,
        into: collector()
      ] ++ Application.get_env(:fountain, :webhook_req_options, [])
    )
  end

  # Stop reading at the cap and drop the connection. `resp.body` starts as ""
  # when `:into` is a function.
  defp collector do
    cap = Delivery.max_body_bytes()

    fn {:data, data}, {req, resp} ->
      body = (resp.body || "") <> data

      if byte_size(body) >= cap do
        {:halt, {req, %{resp | body: binary_part(body, 0, cap)}}}
      else
        {:cont, {req, %{resp | body: body}}}
      end
    end
  end
end
