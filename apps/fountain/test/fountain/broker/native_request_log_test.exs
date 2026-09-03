defmodule Fountain.Broker.Native.RequestLogTest do
  # The native backend's stored egress log (#1486, ADR 0019 gate 4): the
  # buffered writer, the page the /egress endpoint reads, the cursor, and the
  # retention sweep.
  use Fountain.DataCase, async: true

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.Broker.Native.Request
  alias Fountain.Broker.Native.RequestLog

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    # The writer runs in its own process, so it needs this test's connection.
    pid =
      start_supervised!({RequestLog, name: :"request_log_#{System.unique_integer([:positive])}"})

    Sandbox.allow(Fountain.Repo, self(), pid)

    {:ok, user: user, conv: conv, log: pid}
  end

  defp row(conv, user, overrides \\ %{}) do
    Map.merge(
      %{
        conversation_id: conv.id,
        user_id: user.id,
        method: "GET",
        host: "api.github.com",
        path: "/user",
        outcome: "injected",
        service: "github-api",
        credential_keys: ["GITHUB_TOKEN"],
        inserted_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "record/2" do
    test "buffers and writes a row the page reads back", ctx do
      assert :ok = RequestLog.record(row(ctx.conv, ctx.user), ctx.log)
      assert :ok = RequestLog.flush(ctx.log)

      assert {:ok, %{events: [event], next: nil}} = RequestLog.page(ctx.conv.id)

      assert %{
               method: "GET",
               host: "api.github.com",
               path: "/user",
               service: "github-api",
               credential_keys: ["GITHUB_TOKEN"]
             } = event

      # Unwritten until the proxy frames responses, and nil rather than absent
      # so the shape matches the Agent Vault backend row for row.
      assert event.status == nil
      assert event.latency_ms == nil
      assert event.error == nil
      assert %DateTime{} = event.at
      assert is_integer(event.id)
    end

    test "writes the whole buffer in one go once it fills", ctx do
      for i <- 1..205, do: RequestLog.record(row(ctx.conv, ctx.user, %{path: "/#{i}"}), ctx.log)
      assert :ok = RequestLog.flush(ctx.log)

      assert Repo.aggregate(Request, :count, :id) == 205
    end

    test "a row the database rejects costs the batch, not the writer", ctx do
      log =
        capture_log(fn ->
          RequestLog.record(
            row(ctx.conv, ctx.user, %{conversation_id: Ecto.UUID.generate()}),
            ctx.log
          )

          RequestLog.flush(ctx.log)
        end)

      assert log =~ "broker request log"
      assert Process.alive?(ctx.log)

      # And the next batch still lands.
      RequestLog.record(row(ctx.conv, ctx.user), ctx.log)
      RequestLog.flush(ctx.log)
      assert {:ok, %{events: [_]}} = RequestLog.page(ctx.conv.id)
    end

    test "a cast to a writer that is not running is not an error", ctx do
      assert :ok = RequestLog.record(row(ctx.conv, ctx.user), :no_such_request_log)
    end
  end

  describe "page/2" do
    setup ctx do
      for i <- 1..5 do
        RequestLog.record(row(ctx.conv, ctx.user, %{path: "/#{i}"}), ctx.log)
        RequestLog.flush(ctx.log)
      end

      :ok
    end

    test "is newest first", ctx do
      assert {:ok, %{events: events}} = RequestLog.page(ctx.conv.id)
      assert Enum.map(events, & &1.path) == ~w(/5 /4 /3 /2 /1)
    end

    test "the cursor walks backwards through the ids", ctx do
      assert {:ok, %{events: first, next: next}} = RequestLog.page(ctx.conv.id, limit: 2)
      assert Enum.map(first, & &1.path) == ~w(/5 /4)
      assert is_integer(next)

      assert {:ok, %{events: second, next: next2}} =
               RequestLog.page(ctx.conv.id, limit: 2, before: next)

      assert Enum.map(second, & &1.path) == ~w(/3 /2)

      assert {:ok, %{events: third, next: nil}} =
               RequestLog.page(ctx.conv.id, limit: 2, before: next2)

      assert Enum.map(third, & &1.path) == ~w(/1)
    end

    test "shows one conversation only", ctx do
      other = insert_conversation(user_id: ctx.user.id, agent: insert_agent(user_id: ctx.user.id))
      assert {:ok, %{events: [], next: nil}} = RequestLog.page(other.id)
    end
  end

  describe "sweep/1" do
    test "deletes rows older than the cutoff and leaves the rest", ctx do
      old = DateTime.add(DateTime.utc_now(), -8 * 24 * 3600, :second)
      RequestLog.record(row(ctx.conv, ctx.user, %{path: "/old", inserted_at: old}), ctx.log)
      RequestLog.record(row(ctx.conv, ctx.user, %{path: "/new"}), ctx.log)
      RequestLog.flush(ctx.log)

      cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
      assert RequestLog.sweep(cutoff) == 1

      assert {:ok, %{events: [%{path: "/new"}]}} = RequestLog.page(ctx.conv.id)
    end
  end

  test "deleting the conversation takes its rows with it", ctx do
    RequestLog.record(row(ctx.conv, ctx.user), ctx.log)
    RequestLog.flush(ctx.log)

    Repo.delete!(ctx.conv)

    assert Repo.aggregate(Request, :count, :id) == 0
  end
end
