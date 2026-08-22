defmodule Fountain.Workers.WebhookDeliveryTest do
  @moduledoc """
  One delivery, end to end (#700, ADR 0024): what goes on the wire, what is
  recorded, and what the worker refuses to do.

  The receiver is a `Req.Test` plug (config/test.exs), so a path that forgot
  to stub would fail loudly rather than reaching a real host. Endpoint URLs
  are IP literals so nothing here depends on DNS.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Webhooks
  alias Fountain.Webhooks.{Delivery, Endpoint, Signature}
  alias Fountain.Workers.WebhookDelivery

  @url "http://93.184.216.34:9000/hooks/f"

  defp endpoint_for(user, url \\ @url) do
    {:ok, {endpoint, secret}} =
      Webhooks.create_endpoint(user.id, %{"url" => url, "event_types" => ["*"]})

    {endpoint, secret}
  end

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "918273",
        "type" => "conversation.turn.done",
        "created_at" => "2026-08-22T18:30:00.123456Z",
        "data" => %{"conversation_id" => "abc", "stage" => "turn", "state" => "done"}
      },
      overrides
    )
  end

  defp job(endpoint, payload, opts \\ []) do
    %Oban.Job{
      args: %{"endpoint_id" => endpoint.id, "payload" => payload},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 8)
    }
  end

  defp stub(status, body \\ "ok", test \\ self()) do
    Req.Test.stub(Fountain.Webhooks, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:received, conn, raw})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(status, body)
    end)
  end

  defp last_delivery(endpoint) do
    endpoint |> Webhooks.list_deliveries(10) |> List.first()
  end

  # `Oban.insert/1` returns a job with `attempt: 0`; Oban stamps 1 when it
  # runs one. Calling `perform/1` by hand skips that, so a job that came from
  # the queue has to be aged by a test that asserts on the attempt count.
  defp executed(%Oban.Job{} = job), do: %{job | attempt: 1, max_attempts: 8}

  describe "a delivery the receiver accepts" do
    test "posts the payload, signed with the endpoint's secret" do
      user = insert_verified_user()
      {endpoint, secret} = endpoint_for(user)
      stub(200)

      assert :ok = WebhookDelivery.perform(job(endpoint, payload()))

      assert_received {:received, conn, raw}

      assert conn.method == "POST"
      assert conn.request_path == "/hooks/f"
      assert Jason.decode!(raw) == payload()

      [signature] = Plug.Conn.get_req_header(conn, "fountain-signature")
      assert :ok = Signature.verify(signature, raw, secret)
    end

    test "carries the event id, type and attempt in headers" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(200)

      assert :ok = WebhookDelivery.perform(job(endpoint, payload(), attempt: 3))

      assert_received {:received, conn, _raw}
      assert Plug.Conn.get_req_header(conn, "fountain-event-id") == ["918273"]

      assert Plug.Conn.get_req_header(conn, "fountain-event-type") == [
               "conversation.turn.done"
             ]

      assert Plug.Conn.get_req_header(conn, "fountain-delivery-attempt") == ["3"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    end

    test "sends the original host, not the pinned address" do
      # The request goes to a checked IP; the receiver has to see the host it
      # was configured with, port included, or its vhost will not match.
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(200)

      assert :ok = WebhookDelivery.perform(job(endpoint, payload()))

      assert_received {:received, conn, _raw}
      assert Plug.Conn.get_req_header(conn, "host") == ["93.184.216.34:9000"]
    end

    test "records the attempt with its status and duration" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(204, "")

      assert :ok = WebhookDelivery.perform(job(endpoint, payload()))

      assert %Delivery{} = delivery = last_delivery(endpoint)
      assert delivery.status_code == 204
      assert delivery.event_id == "918273"
      assert delivery.event_type == "conversation.turn.done"
      assert delivery.attempt == 1
      assert delivery.error == nil
      assert is_integer(delivery.duration_ms)
      # Kept, so a redelivery replays exactly what was sent.
      assert delivery.payload == payload()
    end

    test "clears a run of failures" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      :ok = Webhooks.note_failure(endpoint, "HTTP 500")
      stub(200)

      assert :ok = WebhookDelivery.perform(job(endpoint, payload()))

      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 0
    end
  end

  describe "a receiver that says no" do
    test "returns an error so Oban retries, and records what it said" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(500, ~s({"error":"boom"}))

      assert {:error, _reason} = WebhookDelivery.perform(job(endpoint, payload()))

      delivery = last_delivery(endpoint)
      assert delivery.status_code == 500
      assert delivery.error == "HTTP 500"
      assert delivery.response_body =~ "boom"
    end

    test "a 3xx is a failure, not a place to go next" do
      # A 302 to 169.254.169.254 would defeat every check in Url, so the
      # worker never follows one.
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      Req.Test.stub(Fountain.Webhooks, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, _} = WebhookDelivery.perform(job(endpoint, payload()))

      delivery = last_delivery(endpoint)
      assert delivery.status_code == 302
      assert delivery.error =~ "does not follow redirects"
    end

    test "the last attempt counts the event as failed" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(500)

      assert {:error, _} =
               WebhookDelivery.perform(job(endpoint, payload(), attempt: 8, max_attempts: 8))

      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 1
    end

    test "an attempt short of the last one does not count the event yet" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(500)

      assert {:error, _} =
               WebhookDelivery.perform(job(endpoint, payload(), attempt: 7, max_attempts: 8))

      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 0
    end

    test "an enormous response body costs a few KB, not a few GB" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(500, String.duplicate("x", 5_000_000))

      assert {:error, _} = WebhookDelivery.perform(job(endpoint, payload()))

      assert byte_size(last_delivery(endpoint).response_body) <= Delivery.max_body_bytes()
    end
  end

  describe "what never leaves the building" do
    test "an endpoint whose URL now resolves somewhere private is not called" do
      # The address check runs at request time, so an endpoint saved when its
      # host was public still cannot be delivered to once it is not. Written
      # here by moving the row underneath the worker, which is what a
      # rebinding attack does with DNS.
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      Repo.update_all(
        from(e in Endpoint, where: e.id == ^endpoint.id),
        set: [url: "http://169.254.169.254/latest/meta-data/"]
      )

      Req.Test.stub(Fountain.Webhooks, fn _conn ->
        flunk("the worker made a request to a blocked address")
      end)

      assert {:error, _} = WebhookDelivery.perform(job(endpoint, payload()))

      delivery = last_delivery(endpoint)
      assert delivery.status_code == nil
      assert delivery.error =~ "link-local"
    end

    test "an endpoint deleted while its job waited is a no-op" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      {:ok, _} = Webhooks.delete_endpoint(endpoint)

      Req.Test.stub(Fountain.Webhooks, fn _conn ->
        flunk("the worker called a deleted endpoint")
      end)

      assert :ok = WebhookDelivery.perform(job(endpoint, payload()))
    end

    test "an endpoint disabled while its job waited is a no-op" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      {:ok, _} = Webhooks.disable_endpoint(endpoint, "switched off")

      Req.Test.stub(Fountain.Webhooks, fn _conn ->
        flunk("the worker called a disabled endpoint")
      end)

      assert :ok = WebhookDelivery.perform(job(endpoint, payload()))
    end
  end

  describe "test events and redelivery" do
    test "a test event is signed like any other and is not a conversation event" do
      user = insert_verified_user()
      {endpoint, secret} = endpoint_for(user)
      stub(200)

      {:ok, job} = Webhooks.deliver_test_event(endpoint)
      assert :ok = WebhookDelivery.perform(executed(job))

      assert_received {:received, conn, raw}
      assert Jason.decode!(raw)["type"] == "webhook.test"
      refute Jason.decode!(raw)["type"] =~ "conversation."

      [signature] = Plug.Conn.get_req_header(conn, "fountain-signature")
      assert :ok = Signature.verify(signature, raw, secret)
    end

    test "a test event goes out whatever the endpoint's filter says" do
      user = insert_verified_user()

      {:ok, {endpoint, _}} =
        Webhooks.create_endpoint(user.id, %{
          "url" => @url,
          "event_types" => ["conversation.provision.failed"]
        })

      stub(200)

      {:ok, job} = Webhooks.deliver_test_event(endpoint)
      assert :ok = WebhookDelivery.perform(executed(job))

      assert_received {:received, _conn, _raw}
    end

    test "a redelivery replays the recorded payload with a fresh attempt count" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      stub(500)

      assert {:error, _} =
               WebhookDelivery.perform(job(endpoint, payload(), attempt: 4, max_attempts: 8))

      failed = last_delivery(endpoint)
      assert failed.attempt == 4

      stub(200)
      {:ok, retry} = Webhooks.redeliver(failed)
      assert :ok = WebhookDelivery.perform(executed(retry))

      assert_received {:received, _conn, raw}
      assert Jason.decode!(raw) == payload()
      assert last_delivery(endpoint).attempt == 1
    end
  end
end
