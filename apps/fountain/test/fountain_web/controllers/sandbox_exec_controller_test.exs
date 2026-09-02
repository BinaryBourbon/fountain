defmodule FountainWeb.SandboxExecControllerTest do
  # POST /api/sandboxes/:id/exec and GET /api/sandboxes/:id/files, at
  # the door: who may, on which machine, what comes back, what is audited.
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Audit
  alias Fountain.Conversations.SandboxCommands

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, runtime: "claude")

    sandbox =
      insert_sandbox(user_id: user.id, status: "ready", agent_id: agent.id, provider: "sprites")

    # A turn in flight does not block a look at the tree.
    _busy =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "running")

    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox}
  end

  defp exec(ctx, id, body) do
    ctx.conn |> authed_with_key(ctx.raw_key) |> post_json("/api/sandboxes/#{id}/exec", body)
  end

  defp file(ctx, id, path) do
    ctx.conn |> authed_with_key(ctx.raw_key) |> get("/api/sandboxes/#{id}/files", path: path)
  end

  describe "POST /api/sandboxes/:id/exec" do
    test "runs the command on the sandbox's handle and answers with output, exit code and duration",
         ctx do
      test_pid = self()

      stub(Managoat.Sandbox, :exec, fn handle, cmd, args, opts ->
        send(test_pid, {:exec, handle, cmd, args, opts})
        {:ok, "diff --git a/x b/x\n", 0}
      end)

      data =
        ctx
        |> exec(ctx.sandbox.id, %{
          "command" => "git",
          "args" => ["diff", "main"],
          "cwd" => "/home/sprite/work/app",
          "timeout_ms" => 5000
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"output" => "diff --git a/x b/x\n", "exit_code" => 0, "truncated" => false} = data
      assert is_integer(data["duration_ms"])

      assert_received {:exec, handle, "git", ["diff", "main"], opts}
      assert handle.name == ctx.sandbox.sprite_name
      assert opts[:dir] == "/home/sprite/work/app"
      assert opts[:timeout] == 5000
      assert opts[:stderr_to_stdout] == true

      # Audited by size and exit code — never the command line or the output.
      [event] =
        Audit.list_for_user(ctx.user.id) |> Enum.filter(&(&1.action == "sandbox.exec"))

      assert event.resource_id == ctx.sandbox.id
      assert event.metadata["exit_code"] == 0
      assert event.metadata["output_bytes"] == 19
      assert event.metadata["args"] == 2
      refute inspect(event.metadata) =~ "diff"
    end

    test "a non-zero exit is still a 200 with the code; long output is cut and says so", ctx do
      stub(Managoat.Sandbox, :exec, fn _h, _cmd, _args, _opts ->
        {:ok, String.duplicate("x", SandboxCommands.output_cap() + 10), 3}
      end)

      data =
        ctx
        |> exec(ctx.sandbox.id, %{"command" => "false"})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["exit_code"] == 3
      assert data["truncated"] == true
      assert byte_size(data["output"]) == SandboxCommands.output_cap()
    end

    test "the timeout is clamped, and a command that outlives it is a 504", ctx do
      test_pid = self()

      stub(Managoat.Sandbox, :exec, fn _h, _cmd, _args, opts ->
        send(test_pid, {:timeout, opts[:timeout]})
        {:error, {:unavailable, {:exec_timeout, opts[:timeout]}}}
      end)

      assert %{"error" => "exec_timeout"} =
               ctx
               |> exec(ctx.sandbox.id, %{
                 "command" => "sleep",
                 "args" => ["999"],
                 "timeout_ms" => 600_000
               })
               |> json_response(504)

      assert_received {:timeout, 600_000}

      # Over the cap is refused by the schema, not clamped silently.
      assert ctx
             |> exec(ctx.sandbox.id, %{"command" => "sleep", "timeout_ms" => 700_000})
             |> json_response(422)
    end

    test "a sandbox that is not ready is 409 and nothing runs; a parked one is not woken", ctx do
      stub(Managoat.Sandbox, :exec, fn _h, _cmd, _args, _opts ->
        flunk("ran on a parked sandbox")
      end)

      parked = insert_sandbox(user_id: ctx.user.id, status: "suspended", agent_id: ctx.agent.id)

      assert %{"error" => "sandbox_not_ready", "status" => "suspended"} =
               ctx |> exec(parked.id, %{"command" => "true"}) |> json_response(409)
    end

    test "a sandbox the caller does not own, or a made-up id, is 404", ctx do
      theirs = insert_sandbox(user_id: insert_active_user().id, status: "ready")
      assert ctx |> exec(theirs.id, %{"command" => "true"}) |> json_response(404)
      assert ctx |> exec(Ecto.UUID.generate(), %{"command" => "true"}) |> json_response(404)
    end

    test "a sandbox's own per-conversation token is refused", ctx do
      {_record, sprite_key} = insert_sprite_api_key(ctx.user)

      assert ctx.conn
             |> authed_with_key(sprite_key)
             |> post_json("/api/sandboxes/#{ctx.sandbox.id}/exec", %{"command" => "true"})
             |> json_response(403)
    end

    test "a transport failure is a 502 with the reason", ctx do
      stub(Managoat.Sandbox, :exec, fn _h, _cmd, _args, _opts ->
        {:error, {:unavailable, :closed}}
      end)

      assert %{"error" => "sandbox_exec_failed"} =
               ctx |> exec(ctx.sandbox.id, %{"command" => "true"}) |> json_response(502)
    end

    test "the body is checked: a command is required, args are strings", ctx do
      assert ctx |> exec(ctx.sandbox.id, %{}) |> json_response(422)

      assert ctx
             |> exec(ctx.sandbox.id, %{"command" => "ls", "args" => [1]})
             |> json_response(422)
    end
  end

  describe "GET /api/sandboxes/:id/files" do
    test "reads the file through a guarded shell script and answers bytes", ctx do
      test_pid = self()

      stub(Managoat.Sandbox, :exec, fn _h, cmd, args, _opts ->
        send(test_pid, {:exec, cmd, args})
        {:ok, "hello\n", 0}
      end)

      conn = file(ctx, ctx.sandbox.id, "/home/sprite/work/app/README.md")
      assert response(conn, 200) == "hello\n"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-fountain-truncated") == ["false"]

      assert_received {:exec, "sh", ["-c", script, "sh", "/home/sprite/work/app/README.md"]}
      assert script =~ "head -c"
      assert script =~ "exit 44"

      [event] =
        Audit.list_for_user(ctx.user.id)
        |> Enum.filter(&(&1.action == "sandbox.file_read"))

      assert event.metadata["bytes"] == 6
      refute inspect(event.metadata) =~ "README"
    end

    test "a missing file is 404, a directory is 422, and a relative path is refused", ctx do
      stub(Managoat.Sandbox, :exec, fn _h, _cmd, ["-c", _, "sh", path], _opts ->
        case path do
          "/nope" -> {:ok, "", 44}
          "/tmp" -> {:ok, "", 45}
        end
      end)

      assert %{"error" => "file_not_found"} =
               ctx |> file(ctx.sandbox.id, "/nope") |> json_response(404)

      assert %{"error" => "not_a_file"} =
               ctx |> file(ctx.sandbox.id, "/tmp") |> json_response(422)

      assert %{"error" => "invalid_path"} =
               ctx |> file(ctx.sandbox.id, "relative.txt") |> json_response(400)
    end

    test "a long file is cut at the cap and the header says so", ctx do
      stub(Managoat.Sandbox, :exec, fn _h, _cmd, _args, _opts ->
        {:ok, String.duplicate("y", SandboxCommands.file_cap() + 1), 0}
      end)

      conn = file(ctx, ctx.sandbox.id, "/big")
      assert byte_size(response(conn, 200)) == SandboxCommands.file_cap()
      assert get_resp_header(conn, "x-fountain-truncated") == ["true"]
    end

    test "not ready, not owned, and a sprite token are refused like exec", ctx do
      parked = insert_sandbox(user_id: ctx.user.id, status: "suspended", agent_id: ctx.agent.id)
      assert ctx |> file(parked.id, "/x") |> json_response(409)

      theirs = insert_sandbox(user_id: insert_active_user().id, status: "ready")
      assert ctx |> file(theirs.id, "/x") |> json_response(404)

      {_record, sprite_key} = insert_sprite_api_key(ctx.user)

      assert ctx.conn
             |> authed_with_key(sprite_key)
             |> get("/api/sandboxes/#{ctx.sandbox.id}/files", path: "/x")
             |> json_response(403)
    end
  end
end
