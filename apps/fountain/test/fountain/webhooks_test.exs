defmodule Fountain.WebhooksTest do
  @moduledoc """
  The context (#700, ADR 0024): the secret's one-way trip, tenant scoping,
  dispatch off `publish_stage/4`, and the failure counter that switches an
  endpoint off.
  """

  use Fountain.DataCase, async: true

  import Ecto.Query

  alias Fountain.{Audit, Conversations, Repo, Webhooks}
  alias Fountain.Conversations.LogEvent
  alias Fountain.Webhooks.{Delivery, Endpoint}

  defp endpoint_for(user, attrs \\ %{}) do
    {:ok, {endpoint, secret}} =
      Webhooks.create_endpoint(
        user.id,
        Map.merge(%{"url" => "https://hooks.example.com/f"}, attrs)
      )

    {endpoint, secret}
  end

  describe "create_endpoint/3" do
    test "returns the secret once and never stores it in the clear" do
      user = insert_verified_user()
      {endpoint, secret} = endpoint_for(user)

      assert String.starts_with?(secret, "whsec_")
      # Long enough that guessing is not a strategy.
      assert byte_size(secret) > 40

      # Nothing readable is on the row, and the ciphertext is not the secret.
      refute endpoint.secret_ciphertext == secret
      refute String.contains?(endpoint.secret_ciphertext, secret)

      # It comes back only through the tenant's own DEK.
      assert {:ok, ^secret} = Webhooks.secret(Repo.get!(Endpoint, endpoint.id))
    end

    test "defaults to the three events an integrator usually wants" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      assert endpoint.event_types == [
               "conversation.turn.done",
               "conversation.turn.failed",
               "conversation.provision.failed"
             ]
    end

    test "an empty event list falls back to the defaults rather than to silence" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user, %{"event_types" => []})

      assert endpoint.event_types != []
    end

    test "refuses a URL that resolves somewhere private" do
      user = insert_verified_user()

      assert {:error, changeset} =
               Webhooks.create_endpoint(user.id, %{"url" => "http://localhost:9000/hook"})

      assert %{url: [_ | _]} = errors_on(changeset)
    end

    test "refuses an event type nobody can ever receive" do
      user = insert_verified_user()

      assert {:error, changeset} =
               Webhooks.create_endpoint(user.id, %{
                 "url" => "https://hooks.example.com/f",
                 "event_types" => ["conversation.turn.finished"]
               })

      assert %{event_types: [message]} = errors_on(changeset)
      assert message =~ "unknown event"
    end

    test "records the host and the filter, and never the secret" do
      user = insert_verified_user()
      {_endpoint, secret} = endpoint_for(user)

      event =
        user.id
        |> Audit.list_recent_for_user(50)
        |> Enum.find(&(&1.action == "webhook_endpoint.created"))

      assert event.metadata["host"] == "hooks.example.com"
      assert is_list(event.metadata["event_types"])
      refute inspect(event.metadata) =~ secret
      # The path is tenant-chosen text, so it stays out of the trail too.
      refute inspect(event.metadata) =~ "/f"
    end
  end

  describe "rotate_secret/2" do
    test "mints a new secret and stops the old one verifying" do
      user = insert_verified_user()
      {endpoint, first} = endpoint_for(user)

      assert {:ok, {rotated, second}} = Webhooks.rotate_secret(endpoint)

      refute first == second
      assert {:ok, ^second} = Webhooks.secret(rotated)
    end
  end

  describe "tenant scoping" do
    test "another account's endpoint is invisible and unfetchable" do
      mine = insert_verified_user()
      theirs = insert_verified_user()
      {endpoint, _} = endpoint_for(theirs)

      assert Webhooks.list_endpoints(mine.id) == []
      assert Webhooks.get_endpoint(endpoint.id, mine.id) == nil
      assert %Endpoint{} = Webhooks.get_endpoint(endpoint.id, theirs.id)
    end

    test "a delivery is reachable only through its owning endpoint" do
      mine = insert_verified_user()
      theirs = insert_verified_user()
      {endpoint, _} = endpoint_for(theirs)

      {:ok, delivery} =
        Webhooks.record_delivery(%{
          webhook_endpoint_id: endpoint.id,
          event_id: "1",
          event_type: "conversation.turn.done",
          attempt: 1
        })

      assert Webhooks.get_delivery(delivery.id, mine.id) == nil
      assert %Delivery{} = Webhooks.get_delivery(delivery.id, theirs.id)
    end
  end

  describe "dispatch_stage/1" do
    setup do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)

      %{user: user, conv: conv}
    end

    defp jobs_for(endpoint) do
      Repo.all(
        from j in Oban.Job,
          where: fragment("?->>'endpoint_id' = ?", j.args, ^endpoint.id),
          order_by: j.id
      )
    end

    test "enqueues one job per matching endpoint", %{user: user, conv: conv} do
      {matching, _} = endpoint_for(user, %{"event_types" => ["conversation.turn.done"]})
      {other, _} = endpoint_for(user, %{"event_types" => ["conversation.provision.failed"]})

      Conversations.publish_stage(conv.id, "turn", "done", %{turn_id: nil})

      assert [job] = jobs_for(matching)
      assert job.args["payload"]["type"] == "conversation.turn.done"
      assert jobs_for(other) == []
    end

    test "the payload carries ids and a stage, and no conversation content",
         %{user: user, conv: conv} do
      {endpoint, _} = endpoint_for(user, %{"event_types" => ["*"]})

      Conversations.publish_stage(conv.id, "turn", "done", %{
        secret_looking_thing: "sk-live-do-not-leak",
        turn_id: nil
      })

      assert [job] = jobs_for(endpoint)
      payload = job.args["payload"]

      assert payload["type"] == "conversation.turn.done"
      assert payload["data"]["conversation_id"] == conv.id
      assert payload["data"]["agent_id"] == conv.agent_id
      assert payload["data"]["stage"] == "turn"
      assert payload["data"]["state"] == "done"

      # The stage metadata is not the payload. Whatever a call site put in
      # `meta` stays on the log event and out of the callback.
      refute inspect(payload) =~ "sk-live-do-not-leak"

      assert Map.keys(payload["data"]) |> Enum.sort() == [
               "agent_id",
               "conversation_id",
               "duration_ms",
               "parent_conversation_id",
               "stage",
               "state",
               "status",
               "turn_id"
             ]
    end

    test "output events never dispatch", %{user: user, conv: conv} do
      {endpoint, _} = endpoint_for(user, %{"event_types" => ["*"]})

      Conversations.log!(%{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "a chatty turn"
      })

      assert jobs_for(endpoint) == []
    end

    test "a disabled endpoint gets nothing", %{user: user, conv: conv} do
      {endpoint, _} = endpoint_for(user, %{"event_types" => ["*"]})
      {:ok, endpoint} = Webhooks.disable_endpoint(endpoint, "test")

      Conversations.publish_stage(conv.id, "turn", "done")

      assert jobs_for(endpoint) == []
    end

    test "another account's endpoint gets nothing", %{conv: conv} do
      stranger = insert_verified_user()
      {endpoint, _} = endpoint_for(stranger, %{"event_types" => ["*"]})

      Conversations.publish_stage(conv.id, "turn", "done")

      assert jobs_for(endpoint) == []
    end

    test "an id in the payload is the log event id the SSE stream sends",
         %{user: user, conv: conv} do
      {endpoint, _} = endpoint_for(user, %{"event_types" => ["*"]})

      event = Conversations.publish_stage(conv.id, "turn", "done")

      assert [job] = jobs_for(endpoint)
      assert job.args["payload"]["id"] == to_string(event.id)
    end

    test "dispatch survives anything it finds, including finding nothing" do
      # Best-effort on the conversation's own hot path: a publish that raises
      # is a stuck agent. Called directly with an event whose conversation is
      # not there, and with one that is malformed.
      assert :ok =
               Webhooks.dispatch_stage(%LogEvent{
                 id: 1,
                 kind: "stage",
                 stage: "turn",
                 state: "done",
                 conversation_id: Ecto.UUID.generate(),
                 inserted_at: DateTime.utc_now()
               })

      assert :ok = Webhooks.dispatch_stage(%LogEvent{kind: "stage", conversation_id: nil})
      assert :ok = Webhooks.dispatch_stage(%LogEvent{kind: "output"})
    end
  end

  describe "failure bookkeeping" do
    test "a success clears the counter" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      Repo.update_all(from(e in Endpoint, where: e.id == ^endpoint.id),
        set: [consecutive_failures: 3]
      )

      :ok = Webhooks.note_success(endpoint)

      assert Repo.get!(Endpoint, endpoint.id).consecutive_failures == 0
    end

    test "the endpoint is switched off at the threshold, and its owner told" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      for _ <- 1..Webhooks.failure_threshold() do
        :ok = Webhooks.note_failure(Repo.get!(Endpoint, endpoint.id), "HTTP 500")
      end

      reloaded = Repo.get!(Endpoint, endpoint.id)
      assert reloaded.status == "disabled"
      assert reloaded.disabled_at
      assert reloaded.disabled_reason =~ "failed to deliver"

      assert Repo.exists?(
               from j in Oban.Job,
                 where:
                   j.worker == "Fountain.Workers.WebhookEmail" and
                     fragment("?->>'endpoint_id' = ?", j.args, ^endpoint.id)
             )
    end

    test "one failure short of the threshold leaves it active" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      for _ <- 1..(Webhooks.failure_threshold() - 1) do
        :ok = Webhooks.note_failure(Repo.get!(Endpoint, endpoint.id), "HTTP 500")
      end

      assert Repo.get!(Endpoint, endpoint.id).status == "active"
    end

    test "the auto-disable is attributed to the worker, not to the account" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      for _ <- 1..Webhooks.failure_threshold() do
        :ok = Webhooks.note_failure(Repo.get!(Endpoint, endpoint.id), "HTTP 500")
      end

      event =
        user.id
        |> Audit.list_recent_for_user(50)
        |> Enum.find(&(&1.action == "webhook_endpoint.disabled"))

      assert event.actor == "system:webhook_delivery"
    end

    test "enabling clears the counter and the reason" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)
      {:ok, disabled} = Webhooks.disable_endpoint(endpoint, "gone")

      {:ok, _} = Webhooks.enable_endpoint(disabled)

      reloaded = Repo.get!(Endpoint, endpoint.id)
      assert reloaded.status == "active"
      assert reloaded.consecutive_failures == 0
      assert reloaded.disabled_at == nil
      assert reloaded.disabled_reason == nil
    end
  end

  describe "deleting" do
    test "the delivery log goes with the endpoint" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      {:ok, _} =
        Webhooks.record_delivery(%{
          webhook_endpoint_id: endpoint.id,
          event_id: "1",
          event_type: "conversation.turn.done",
          attempt: 1
        })

      {:ok, _} = Webhooks.delete_endpoint(endpoint)

      assert Repo.aggregate(
               from(d in Delivery, where: d.webhook_endpoint_id == ^endpoint.id),
               :count
             ) == 0
    end
  end

  describe "the delivery row" do
    test "truncates a response body rather than storing all of it" do
      user = insert_verified_user()
      {endpoint, _} = endpoint_for(user)

      {:ok, delivery} =
        Webhooks.record_delivery(%{
          webhook_endpoint_id: endpoint.id,
          event_id: "1",
          event_type: "conversation.turn.done",
          attempt: 1,
          response_body: String.duplicate("x", 100_000)
        })

      assert byte_size(delivery.response_body) <= Delivery.max_body_bytes()
    end
  end
end

defmodule Fountain.WebhooksDisabledTest do
  @moduledoc """
  `WEBHOOKS_ENABLED=false`. Application env, so this cannot be `async: true`
  beside the tests that rely on dispatch running.
  """

  use Fountain.DataCase, async: false

  import Ecto.Query

  alias Fountain.{Conversations, Repo, Webhooks}

  setup do
    original = Application.get_env(:fountain, :webhooks_enabled)
    Application.put_env(:fountain, :webhooks_enabled, false)
    on_exit(fn -> Application.put_env(:fountain, :webhooks_enabled, original) end)
    :ok
  end

  test "nothing is dispatched, and the endpoint stays saved" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, {endpoint, _secret}} =
      Webhooks.create_endpoint(user.id, %{
        "url" => "https://hooks.example.com/f",
        "event_types" => ["*"]
      })

    Conversations.publish_stage(conv.id, "turn", "done")

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: fragment("?->>'endpoint_id' = ?", j.args, ^endpoint.id)
             ),
             :count
           ) == 0

    # Switched off means "stop delivering", not "lose the configuration".
    assert [_] = Webhooks.list_endpoints(user.id)
  end
end
