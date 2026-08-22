defmodule FountainWeb.WebhookEndpointControllerTest do
  @moduledoc """
  `/api/webhooks` (#700, ADR 0024). The three things worth pinning at this
  layer: the secret appears in exactly one response shape, a sandbox token
  cannot reach any of it, and another tenant's endpoint is a 404 rather than
  a 403.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Webhooks

  setup %{conn: conn} do
    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)
    %{conn: authed_with_key(conn, raw_key), user: user}
  end

  defp create(conn, attrs \\ %{}) do
    body = Map.merge(%{"url" => "https://hooks.example.com/f"}, attrs)
    post(conn, "/api/webhooks", body)
  end

  describe "POST /api/webhooks" do
    test "creates an endpoint and returns the secret once", %{conn: conn} do
      body = conn |> create() |> json_response(201)

      assert body["data"]["url"] == "https://hooks.example.com/f"
      assert body["data"]["status"] == "active"
      assert String.starts_with?(body["secret"], "whsec_")

      # And never again, on any other read.
      %{"data" => listed} = conn |> get("/api/webhooks") |> json_response(200)
      refute Enum.any?(listed, &Map.has_key?(&1, "secret"))

      shown = conn |> get("/api/webhooks/#{body["data"]["id"]}") |> json_response(200)
      refute Map.has_key?(shown["data"], "secret")
      refute Map.has_key?(shown["data"], "secret_ciphertext")
    end

    test "422s a URL pointing somewhere private", %{conn: conn} do
      body =
        conn
        |> create(%{"url" => "http://localhost:9000/hook"})
        |> json_response(422)

      assert body["errors"]["url"]
    end

    test "422s an unknown event type", %{conn: conn} do
      body =
        conn
        |> create(%{"event_types" => ["conversation.turn.finished"]})
        |> json_response(422)

      assert body["errors"]["event_types"]
    end

    test "subscribes to the defaults when none are named", %{conn: conn} do
      body = conn |> create() |> json_response(201)

      assert "conversation.turn.done" in body["data"]["event_types"]
      assert "conversation.provision.failed" in body["data"]["event_types"]
    end
  end

  describe "GET /api/webhooks" do
    test "lists only the caller's", %{conn: conn, user: user} do
      {:ok, {mine, _}} = Webhooks.create_endpoint(user.id, %{"url" => "https://a.example.com/h"})

      stranger = insert_verified_user()

      {:ok, {theirs, _}} =
        Webhooks.create_endpoint(stranger.id, %{"url" => "https://b.example.com/h"})

      %{"data" => data} = conn |> get("/api/webhooks") |> json_response(200)

      assert Enum.map(data, & &1["id"]) == [mine.id]
      refute theirs.id in Enum.map(data, & &1["id"])
    end
  end

  describe "another tenant's endpoint" do
    setup %{user: _user} do
      stranger = insert_verified_user()

      {:ok, {endpoint, _}} =
        Webhooks.create_endpoint(stranger.id, %{"url" => "https://b.example.com/h"})

      %{theirs: endpoint}
    end

    test "is a 404 on every route, not a 403", %{conn: conn, theirs: theirs} do
      assert conn |> get("/api/webhooks/#{theirs.id}") |> json_response(404)

      assert conn
             |> patch("/api/webhooks/#{theirs.id}", %{"description" => "x"})
             |> json_response(404)

      assert conn |> delete("/api/webhooks/#{theirs.id}") |> json_response(404)
      assert conn |> post("/api/webhooks/#{theirs.id}/test", %{}) |> json_response(404)
      assert conn |> post("/api/webhooks/#{theirs.id}/rotate-secret", %{}) |> json_response(404)
      assert conn |> get("/api/webhooks/#{theirs.id}/deliveries") |> json_response(404)
    end
  end

  describe "PATCH /api/webhooks/:id" do
    test "changes the filter and the description", %{conn: conn} do
      %{"data" => %{"id" => id}} = conn |> create() |> json_response(201)

      body =
        conn
        |> patch("/api/webhooks/#{id}", %{
          "description" => "ci",
          "event_types" => ["conversation.turn.*"]
        })
        |> json_response(200)

      assert body["data"]["description"] == "ci"
      assert body["data"]["event_types"] == ["conversation.turn.*"]
    end

    test "status goes through the context, so resuming clears the failure count",
         %{conn: conn, user: user} do
      %{"data" => %{"id" => id}} = conn |> create() |> json_response(201)
      endpoint = Webhooks.get_endpoint(id, user.id)

      for _ <- 1..Webhooks.failure_threshold() do
        :ok = Webhooks.note_failure(Webhooks.get_endpoint(id, user.id), "HTTP 500")
      end

      assert Webhooks.get_endpoint(id, user.id).status == "disabled"

      body = conn |> patch("/api/webhooks/#{id}", %{"status" => "active"}) |> json_response(200)

      assert body["data"]["status"] == "active"
      assert body["data"]["consecutive_failures"] == 0
      assert body["data"]["disabled_reason"] == nil
      assert endpoint.id == id
    end

    test "pausing records a reason", %{conn: conn, user: user} do
      %{"data" => %{"id" => id}} = conn |> create() |> json_response(201)

      body = conn |> patch("/api/webhooks/#{id}", %{"status" => "disabled"}) |> json_response(200)

      assert body["data"]["status"] == "disabled"
      assert Webhooks.get_endpoint(id, user.id).disabled_reason =~ "owner"
    end
  end

  describe "POST /api/webhooks/:id/rotate-secret" do
    test "returns a different secret", %{conn: conn} do
      created = conn |> create() |> json_response(201)

      rotated =
        conn
        |> post("/api/webhooks/#{created["data"]["id"]}/rotate-secret", %{})
        |> json_response(200)

      assert String.starts_with?(rotated["secret"], "whsec_")
      refute rotated["secret"] == created["secret"]
    end
  end

  describe "POST /api/webhooks/:id/test" do
    test "queues a test event", %{conn: conn} do
      %{"data" => %{"id" => id}} = conn |> create() |> json_response(201)

      body = conn |> post("/api/webhooks/#{id}/test", %{}) |> json_response(202)

      assert body == %{"queued" => true, "event_type" => "webhook.test"}
    end
  end

  describe "deliveries" do
    setup %{conn: conn, user: user} do
      %{"data" => %{"id" => id}} = conn |> create() |> json_response(201)
      endpoint = Webhooks.get_endpoint(id, user.id)

      {:ok, delivery} =
        Webhooks.record_delivery(%{
          webhook_endpoint_id: endpoint.id,
          event_id: "42",
          event_type: "conversation.turn.done",
          attempt: 2,
          status_code: 500,
          duration_ms: 91,
          error: "HTTP 500",
          response_body: "boom",
          payload: %{"id" => "42", "type" => "conversation.turn.done"}
        })

      %{endpoint: endpoint, delivery: delivery}
    end

    test "lists attempts with what the receiver said", %{conn: conn, endpoint: endpoint} do
      %{"data" => [row]} =
        conn |> get("/api/webhooks/#{endpoint.id}/deliveries") |> json_response(200)

      assert row["event_type"] == "conversation.turn.done"
      assert row["attempt"] == 2
      assert row["status_code"] == 500
      assert row["duration_ms"] == 91
      assert row["response_body"] == "boom"
      # The stored payload is for redelivery, not for a listing.
      refute Map.has_key?(row, "payload")
    end

    test "redelivers one by hand", %{conn: conn, endpoint: endpoint, delivery: delivery} do
      body =
        conn
        |> post("/api/webhooks/#{endpoint.id}/deliveries/#{delivery.id}/redeliver", %{})
        |> json_response(202)

      assert body["queued"] == true
      assert body["event_type"] == "conversation.turn.done"
    end

    test "404s a delivery id that is not this endpoint's", %{conn: conn, endpoint: endpoint} do
      assert conn
             |> post(
               "/api/webhooks/#{endpoint.id}/deliveries/#{Ecto.UUID.generate()}/redeliver",
               %{}
             )
             |> json_response(404)
    end
  end

  describe "DELETE /api/webhooks/:id" do
    test "removes it", %{conn: conn, user: user} do
      %{"data" => %{"id" => id}} = conn |> create() |> json_response(201)

      assert conn |> delete("/api/webhooks/#{id}") |> response(204)
      refute Webhooks.get_endpoint(id, user.id)
    end
  end

  describe "scope" do
    test "a sandbox's per-conversation token cannot reach any of it", %{conn: conn} do
      # Same gate as key management: an agent must not be able to point the
      # account's lifecycle events at a URL of its choosing.
      sandbox_user = insert_verified_user()
      {_record, sprite_key} = insert_sprite_api_key(sandbox_user)
      sprite_conn = authed_with_key(conn, sprite_key)

      assert sprite_conn |> get("/api/webhooks") |> json_response(403)

      assert sprite_conn
             |> post("/api/webhooks", %{"url" => "https://x.example.com/h"})
             |> json_response(403)
    end
  end
end
