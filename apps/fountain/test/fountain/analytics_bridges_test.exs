defmodule Fountain.AnalyticsBridgesTest do
  @moduledoc """
  The three choke points that feed PostHog without any call site knowing.

  These tests are the reason the integration can claim coverage: they assert
  that instrumenting a new action requires nothing beyond auditing it,
  metering it, or publishing its stage — which the code already had to do.
  """

  # Mutates global app env (the PostHog key), so not async.
  use Fountain.DataCase, async: false

  alias Fountain.Analytics
  alias Fountain.Audit
  alias Fountain.Conversations

  setup do
    previous = Application.get_env(:fountain, :posthog_project_api_key)
    Application.put_env(:fountain, :posthog_project_api_key, "phc_test")
    Fountain.FeatureFlags.reset()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fountain, :posthog_project_api_key)
        key -> Application.put_env(:fountain, :posthog_project_api_key, key)
      end

      Fountain.FeatureFlags.reset()
    end)

    test = self()

    Req.Test.stub(Analytics, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posthog, Jason.decode!(body)})
      Req.Test.json(conn, %{"status" => 1})
    end)

    :ok
  end

  # Every capture is one batch of one, because the suite runs the sink in
  # `:inline` mode. Collect the events that arrived rather than asserting on
  # the first, since a single mutation can legitimately produce an `$identify`
  # alongside its event.
  defp captured do
    receive do
      {:posthog, %{"batch" => batch}} -> batch ++ captured()
    after
      0 -> []
    end
  end

  defp event_named(name), do: Enum.find(captured(), &(&1["event"] == name))

  # Creating a fixture is itself an audited mutation — `insert_verified_user/0`
  # registers and verifies an account, which is three events before the test
  # has done anything. Drop whatever the setup produced so each test asserts on
  # its own action only.
  defp forget_setup, do: captured()

  describe "the audit trail" do
    test "an audited mutation becomes a PostHog event under the same name" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "agent.created",
          resource_type: "agent",
          resource_id: Ecto.UUID.generate(),
          user_id: user.id,
          actor: "ui",
          request_ip: "203.0.113.4",
          metadata: %{"runtime" => "claude"}
        })

      assert event = event_named("agent.created")
      assert event["distinct_id"] == user.id
      assert event["properties"]["resource_type"] == "agent"
      assert event["properties"]["actor"] == "ui"
      assert event["properties"]["runtime"] == "claude"
      assert event["properties"]["source"] == "audit"
      assert event["properties"]["$ip"] == "203.0.113.4"
    end

    test "audit metadata is sanitized on the way out" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "vault.secret.write",
          resource_type: "vault",
          user_id: user.id,
          metadata: %{"key" => "GITHUB_TOKEN", "value_bytes" => 40}
        })

      assert event = event_named("vault.secret.write")
      refute Map.has_key?(event["properties"], "key")
      assert event["properties"]["value_bytes"] == 40
    end

    test "a system event that names no tenant is not sent" do
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "sandbox.expired",
          resource_type: "sandbox",
          user_id: nil,
          actor: "system:sandbox_reaper"
        })

      assert captured() == []
    end

    test "an account-shaped action refreshes the person, an ordinary one does not" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "billing.trial.started",
          resource_type: "user",
          user_id: user.id
        })

      assert identify = event_named("$identify")
      assert identify["properties"]["$set"]["email_verified"] == true

      {:ok, _} =
        Audit.record(%{action: "agent.created", resource_type: "agent", user_id: user.id})

      refute event_named("$identify")
    end
  end

  describe "the api pipeline's request log" do
    test "becomes one api.request event with the route as a property" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "DELETE /api/agents/:id",
          resource_type: "request",
          user_id: user.id,
          actor: "api",
          metadata: %{"status" => 204}
        })

      # The name is fixed and the route is data. That is the whole trade: one
      # permanent event definition instead of one per route, and `route` is
      # something PostHog can break down by.
      assert event = event_named("api.request")
      assert event["properties"]["method"] == "DELETE"
      assert event["properties"]["route"] == "/api/agents/:id"
      assert event["properties"]["status"] == 204
      assert event["properties"]["status_class"] == "2xx"
      assert event["properties"]["actor"] == "api"

      # Nothing is captured under the request line itself.
      assert event_named("DELETE /api/agents/:id") == nil
    end

    test "a refused request is captured, which is the point of keeping the row" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "POST /api/conversations",
          resource_type: "request",
          user_id: user.id,
          actor: "api",
          metadata: %{"status" => 403}
        })

      assert event = event_named("api.request")
      assert event["properties"]["status"] == 403
      assert event["properties"]["status_class"] == "4xx"
    end

    test "an unbounded route still yields exactly one event name" do
      # `FountainWeb.Plugs.Audit` records the matched route pattern, so ids do
      # not reach the action. If one ever did — a path that matched no route,
      # via the plug's mask_ids fallback — it lands in a property, where the
      # cost is a property value rather than a permanent event definition.
      user = insert_verified_user()
      forget_setup()

      for id <- 1..3 do
        {:ok, _} =
          Audit.record(%{
            action: "POST /api/conversations/0000000#{id}-0000-4000-8000-000000000000/read",
            resource_type: "request",
            user_id: user.id,
            actor: "api",
            metadata: %{"status" => 200}
          })
      end

      events = captured()

      assert length(events) == 3
      assert Enum.map(events, & &1["event"]) |> Enum.uniq() == ["api.request"]
      assert events |> Enum.map(& &1["properties"]["route"]) |> Enum.uniq() |> length() == 3
    end

    test "a row with no status is captured without inventing one" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "GET /api/agents",
          resource_type: "request",
          user_id: user.id,
          actor: "api"
        })

      assert event = event_named("api.request")
      assert event["properties"]["status"] == nil
      assert event["properties"]["status_class"] == nil
    end

    test "an unauthenticated refusal captures nothing, keeping persons meaning accounts" do
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "POST /api/conversations",
          resource_type: "request",
          user_id: nil,
          actor: "api",
          metadata: %{"status" => 401}
        })

      # `capture/4` drops a subject-less event by rule. A 401 on a bad
      # credential has no principal, so it stays an access-log question and
      # the audit row remains the record of it.
      assert captured() == []
    end
  end

  describe "what the audit trail does not forward" do
    test "an API key the system issued itself is not captured" do
      user = insert_verified_user()
      forget_setup()

      for actor <- ["self", "system:conversation_server", "system:buzz_harness"] do
        {:ok, _} =
          Audit.record(%{
            action: "api_key.created",
            resource_type: "api_key",
            user_id: user.id,
            actor: actor
          })
      end

      assert captured() == []
    end

    test "an API key a person minted is captured" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Audit.record(%{
          action: "api_key.created",
          resource_type: "api_key",
          user_id: user.id,
          actor: "ui"
        })

      assert event = event_named("api_key.created")
      assert event["properties"]["actor"] == "ui"
    end
  end

  describe "the metering choke point" do
    test "a usage event is also a product event" do
      user = insert_verified_user()
      forget_setup()

      {:ok, _} =
        Fountain.Billing.record_usage(user.id, "turn_started", Ecto.UUID.generate(), "turn", %{
          "turn_number" => 2
        })

      assert event = event_named("usage.turn_started")
      assert event["distinct_id"] == user.id
      assert event["properties"]["resource_type"] == "turn"
      assert event["properties"]["turn_number"] == 2
      assert event["properties"]["source"] == "metering"
    end

    test "a rejected usage event sends nothing" do
      user = insert_verified_user()
      forget_setup()

      {:error, :invalid} =
        Fountain.Billing.record_usage(user.id, "not_a_real_type", nil, "turn", %{})

      assert captured() == []
    end
  end

  describe "the conversation stage choke point" do
    test "a finished turn is captured" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)
      forget_setup()

      Conversations.publish_stage(conv.id, "turn", "done", %{
        turn_id: Ecto.UUID.generate(),
        turn_number: 1,
        exit_code: 0
      })

      assert event = event_named("conversation.turn.done")
      assert event["distinct_id"] == user.id
      assert event["properties"]["conversation_id"] == conv.id
      assert event["properties"]["exit_code"] == 0
      assert event["properties"]["source"] == "conversation"
    end

    test "a turn starting is left to the metering side, not double-counted" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)
      forget_setup()

      Conversations.publish_stage(conv.id, "turn", "started", %{turn_number: 1})

      assert captured() == []
    end

    test "provisioning stages are left to the metering side too" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)
      forget_setup()

      Conversations.publish_stage(conv.id, "provision", "done", %{})

      assert captured() == []
    end
  end

  describe "with capture off" do
    setup do
      Application.put_env(:fountain, :analytics_enabled, false)
      on_exit(fn -> Application.delete_env(:fountain, :analytics_enabled) end)
      :ok
    end

    test "no choke point sends anything" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)
      forget_setup()

      {:ok, _} =
        Audit.record(%{action: "agent.created", resource_type: "agent", user_id: user.id})

      {:ok, _} = Fountain.Billing.record_usage(user.id, "turn_started", nil, "turn", %{})
      Conversations.publish_stage(conv.id, "turn", "done", %{})

      assert captured() == []
    end
  end
end
