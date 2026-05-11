defmodule FountainWeb.Plugs.AuditTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.Plugs.Audit

  # Build a minimal conn that has already been "sent" so before_send callbacks fire.
  defp sent_conn(conn) do
    # Simulate a completed response — before_send fires when Plug.Conn.send_resp is called.
    Plug.Conn.send_resp(conn, 200, "ok")
  end

  describe "call/2 — GET requests are not audited" do
    test "returns conn unchanged for GET requests (no before_send hook registered)", %{conn: conn} do
      conn = %{conn | method: "GET", request_path: "/api/conversations"}
      result = Audit.call(conn, [])
      # The conn is returned as-is; no before_send callback added
      assert result == conn
    end
  end

  describe "call/2 — ignored paths are not audited" do
    test "does not register hook for /api/openapi.json even on POST", %{conn: conn} do
      conn = %{conn | method: "POST", request_path: "/api/openapi.json"}
      result = Audit.call(conn, [])
      assert result == conn
    end

    test "does not register hook for /api/docs even on DELETE", %{conn: conn} do
      conn = %{conn | method: "DELETE", request_path: "/api/docs"}
      result = Audit.call(conn, [])
      assert result == conn
    end
  end

  describe "call/2 — write methods create audit events on send" do
    # Verify that the audit plug records an event by sending the conn
    # and checking the audit log — avoids relying on private before_send internals.

    test "POST request creates an audit event", %{conn: conn} do
      user = insert_verified_user()

      conn
      |> Map.merge(%{method: "POST", request_path: "/api/conversations", path_info: ["api", "conversations"], params: %{}})
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.assign(:current_user, user)
      |> Audit.call([])
      |> Plug.Conn.send_resp(201, "ok")

      assert Fountain.Audit.list_recent_for_user(user.id) != []
    end

    test "PUT request creates an audit event", %{conn: conn} do
      user = insert_verified_user()
      id = Ecto.UUID.generate()

      conn
      |> Map.merge(%{method: "PUT", request_path: "/api/agents/#{id}", path_info: ["api", "agents", id], params: %{}})
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.assign(:current_user, user)
      |> Audit.call([])
      |> Plug.Conn.send_resp(200, "ok")

      assert Fountain.Audit.list_recent_for_user(user.id) != []
    end

    test "PATCH request creates an audit event", %{conn: conn} do
      user = insert_verified_user()
      id = Ecto.UUID.generate()

      conn
      |> Map.merge(%{method: "PATCH", request_path: "/api/agents/#{id}", path_info: ["api", "agents", id], params: %{}})
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.assign(:current_user, user)
      |> Audit.call([])
      |> Plug.Conn.send_resp(200, "ok")

      assert Fountain.Audit.list_recent_for_user(user.id) != []
    end

    test "DELETE request creates an audit event", %{conn: conn} do
      user = insert_verified_user()
      id = Ecto.UUID.generate()

      conn
      |> Map.merge(%{method: "DELETE", request_path: "/api/agents/#{id}", path_info: ["api", "agents", id], params: %{}})
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.assign(:current_user, user)
      |> Audit.call([])
      |> Plug.Conn.send_resp(204, "")

      assert Fountain.Audit.list_recent_for_user(user.id) != []
    end
  end

  describe "record/1 — resource derivation via derive_resource" do
    test "derives 'secret' resource when secret_id param is present", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Map.put(:method, "DELETE")
        |> Map.put(:request_path, "/api/environments/env1/secrets/sec1")
        |> Map.put(:path_info, ["api", "environments", "env1", "secrets", "sec1"])
        |> Map.put(:params, %{"secret_id" => "sec1", "environment_id" => "env1"})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_user, user)
        |> Audit.call([])

      # Sending the response triggers the before_send callback which calls Audit.record/1
      sent_conn(conn)

      events = Fountain.Audit.list_recent_for_user(user.id)
      assert events != []
      [event | _] = events
      assert event.resource_type == "secret"
      assert event.resource_id == "sec1"
    end

    test "derives 'vault_secret' resource when vault_id param is present", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Map.put(:method, "DELETE")
        |> Map.put(:request_path, "/api/vaults/vlt1/secrets/vsec1")
        |> Map.put(:path_info, ["api", "vaults", "vlt1", "secrets", "vsec1"])
        |> Map.put(:params, %{"vault_id" => "vlt1", "id" => "vsec1"})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_user, user)
        |> Audit.call([])

      sent_conn(conn)

      events = Fountain.Audit.list_recent_for_user(user.id)
      assert events != []
      [event | _] = events
      assert event.resource_type == "vault_secret"
      assert event.resource_id == "vsec1"
    end

    test "derives 'conversation' resource when conversation_id param is present", %{conn: conn} do
      user = insert_verified_user()
      conv_id = Ecto.UUID.generate()

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/conversations/#{conv_id}/turns")
        |> Map.put(:path_info, ["api", "conversations", conv_id, "turns"])
        |> Map.put(:params, %{"conversation_id" => conv_id})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_user, user)
        |> Audit.call([])

      sent_conn(conn)

      events = Fountain.Audit.list_recent_for_user(user.id)
      assert events != []
      [event | _] = events
      assert event.resource_type == "conversation"
      assert event.resource_id == conv_id
    end

    test "derives resource from path_info when no special params — collection path", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/conversations")
        |> Map.put(:path_info, ["api", "conversations"])
        |> Map.put(:params, %{})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_user, user)
        |> Audit.call([])

      sent_conn(conn)

      events = Fountain.Audit.list_recent_for_user(user.id)
      assert events != []
      [event | _] = events
      # "conversations" with trailing "s" stripped -> "conversation"
      assert event.resource_type == "conversation"
      assert is_nil(event.resource_id)
    end

    test "derives resource and id from path_info — member path", %{conn: conn} do
      user = insert_verified_user()
      resource_id = Ecto.UUID.generate()

      conn =
        conn
        |> Map.put(:method, "DELETE")
        |> Map.put(:request_path, "/api/agents/#{resource_id}")
        |> Map.put(:path_info, ["api", "agents", resource_id])
        |> Map.put(:params, %{})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_user, user)
        |> Audit.call([])

      sent_conn(conn)

      events = Fountain.Audit.list_recent_for_user(user.id)
      assert events != []
      [event | _] = events
      assert event.resource_type == "agent"
      assert event.resource_id == resource_id
    end

    test "falls back to 'unknown' when path_info does not match api pattern", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/webhook")
        |> Map.put(:path_info, ["webhook"])
        |> Map.put(:params, %{})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.assign(:current_user, user)
        |> Audit.call([])

      sent_conn(conn)

      events = Fountain.Audit.list_recent_for_user(user.id)
      assert events != []
      [event | _] = events
      assert event.resource_type == "unknown"
    end

    test "handles nil remote_ip without crashing and creates audit event", %{conn: conn} do
      user = insert_verified_user()

      conn
      |> Map.merge(%{method: "POST", request_path: "/api/conversations", path_info: ["api", "conversations"], params: %{}})
      |> Map.put(:remote_ip, nil)
      |> Plug.Conn.assign(:current_user, user)
      |> Audit.call([])
      |> Plug.Conn.send_resp(201, "ok")

      assert Fountain.Audit.list_recent_for_user(user.id) != []
    end

    test "handles string remote_ip without crashing and creates audit event", %{conn: conn} do
      user = insert_verified_user()

      conn
      |> Map.merge(%{method: "POST", request_path: "/api/conversations", path_info: ["api", "conversations"], params: %{}})
      |> Map.put(:remote_ip, "192.168.1.1")
      |> Plug.Conn.assign(:current_user, user)
      |> Audit.call([])
      |> Plug.Conn.send_resp(201, "ok")

      assert Fountain.Audit.list_recent_for_user(user.id) != []
    end

    test "records user_id as nil when no current_user is assigned", %{conn: conn} do
      # We verify the plug runs and completes without error.
      # The before_send callback calls Audit.record/1 with user_id: nil.
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/conversations")
        |> Map.put(:path_info, ["api", "conversations"])
        |> Map.put(:params, %{})
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Audit.call([])

      # Sending the response fires before_send; it should not raise
      assert %Plug.Conn{} = sent_conn(conn)
    end
  end
end
