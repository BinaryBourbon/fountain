defmodule FountainWeb.DashboardLiveTest do
  @moduledoc """
  The console's home (#867). It is what a new account lands on, so it carries
  what the onboarding wizard used to: the three things that have to be true
  before an agent can run, ticked as they are done — but as a list the
  account can ignore, not four pages it cannot leave.
  """

  use FountainWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  defp max_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  setup %{conn: conn} do
    user = insert_verified_user()

    original = Application.fetch_env(:fountain, :conversations_app_url)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:fountain, :conversations_app_url, v)
        :error -> Application.delete_env(:fountain, :conversations_app_url)
      end
    end)

    Application.put_env(:fountain, :conversations_app_url, "https://apps.test/convs/")

    {:ok, conn: login_user(conn, user), user: user}
  end

  test "a brand-new account is told what is missing, and where to do it", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Before an agent can run"
    assert html =~ "An inference credential"
    assert html =~ "/account/inference-credentials"
    assert html =~ "An agent"
    assert html =~ "/agents/new"
    assert html =~ "https://apps.test/convs/#/new"
  end

  test "a step that is done is ticked and loses its call to action", %{conn: conn, user: user} do
    insert_agent(user_id: user.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "Before an agent can run"
    refute html =~ "/agents/new"
  end

  test "the checklist disappears once there is nothing left in it", %{conn: conn, user: user} do
    insert_agent(user_id: user.id)
    insert_conversation(user_id: user.id)

    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Fountain.InferenceCredentials.put_credential(
        user.id,
        dek,
        :anthropic_api_key,
        "sk-ant-test-key-000000000000",
        actor: "ui"
      )

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    refute html =~ "Before an agent can run"
  end

  # The wizard's last step used to stamp this; the funnel's "onboarded" stage
  # reads it, so the console has to keep it true (#867).
  test "an account with a credential and an agent is marked onboarded", %{conn: conn, user: user} do
    refute user.onboarding_completed_at

    insert_agent(user_id: user.id)
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Fountain.InferenceCredentials.put_credential(
        user.id,
        dek,
        :anthropic_api_key,
        "sk-ant-test-key-000000000000",
        actor: "ui"
      )

    {:ok, _lv, _html} = live(conn, ~p"/dashboard")

    assert Fountain.Accounts.get_user(user.id).onboarding_completed_at
  end

  test "an account still missing a piece is not", %{conn: conn, user: user} do
    insert_agent(user_id: user.id)

    {:ok, _lv, _html} = live(conn, ~p"/dashboard")

    refute Fountain.Accounts.get_user(user.id).onboarding_completed_at
  end

  test "the apps are linked out to, and the primitives linked in to", %{conn: conn, user: user} do
    insert_agent(user_id: user.id)
    insert_env(user_id: user.id)
    insert_vault(user_id: user.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "https://apps.test/convs/"
    assert html =~ ~p"/agents"
    assert html =~ ~p"/environments"
    assert html =~ ~p"/vaults"
  end

  test "a recent conversation links into the app, not to a page that is gone", %{
    conn: conn,
    user: user
  } do
    agent = insert_agent(user_id: user.id, name: "picard")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    assert html =~ "picard"
    assert html =~ "https://apps.test/convs/#/c/#{conv.id}"
    refute html =~ ~s|href="/conversations/#{conv.id}"|
  end

  describe "turn hours" do
    test "the tile reports turn time, not the wall-clock the sandbox was awake", %{
      conn: conn,
      user: user
    } do
      # Ten hours awake, two with a prompt in flight. The old tile said "10h"
      # and a customer could do nothing with it: what their plan includes, and
      # what they are measured on, is the two.
      {period_start, _} = Fountain.Billing.current_month_range()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          provider: "sprites",
          status: "terminated",
          inserted_at: period_start,
          terminated_at: DateTime.add(period_start, 10 * 3600, :second)
        )

      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      {:ok, _} =
        Fountain.Conversations._unsafe_create_turn(%{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "hello",
          status: "completed",
          started_at: period_start,
          ended_at: DateTime.add(period_start, 2 * 3600, :second)
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Turn hours"
      assert html =~ "2.0"
      # Billing is on in test, so the plan's allowance is beside it.
      assert html =~ "of #{Fountain.Plans.included_turn_hours(user)} included"
      # The sandbox side is still available, in the hint where it belongs.
      assert html =~ "sandboxes were awake"
    end
  end

  describe "this month" do
    test "reports conversations, turns, sandbox time and tokens", %{conn: conn, user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Billing.current_month_range()
      at = DateTime.add(period_start, 60, :second)

      # Two usage events of each shape the summary counts.
      Fountain.Billing.record_usage(
        user.id,
        "sandbox_provisioned",
        Ecto.UUID.generate(),
        "sandbox"
      )

      Fountain.Billing.record_usage(user.id, "turn_started", Ecto.UUID.generate(), "turn")
      Fountain.Billing.record_usage(user.id, "turn_started", Ecto.UUID.generate(), "turn")

      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(turn, %{"input" => 1500, "output" => 250})

      Fountain.Repo.update_all(
        from(t in Fountain.Conversations.Turn, where: t.id == ^turn.id),
        set: [inserted_at: max_dt(at, now)]
      )

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "This month"
      assert html =~ "Conversations"
      assert html =~ "Turns"
      # Turn hours, not sandbox time: what a plan includes, and the only one of
      # the two a customer can act on.
      assert html =~ "Turn hours"
      refute html =~ "Sandbox time"
      assert html =~ "Tokens"
      # 1,500 in / 250 out, compacted.
      assert html =~ "1.5k / 250"
    end

    # The tile shipped reading `input` alone, which for a coding agent is a
    # rounding error next to its cached reads.
    test "the tokens tile counts the prompt cache, not just fresh input", %{
      conn: conn,
      user: user
    } do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(turn, %{
          "input" => 1_471,
          "cache_read" => 41_317_595,
          "cache_write" => 3_120_406,
          "output" => 545_912
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # 1,471 + 41,317,595 + 3,120,406 = 44,439,472 in; 545,912 out.
      assert html =~ "44.4M / 545.9k"
      refute html =~ "1.5k / 545.9k"
      # …and the breakdown is on hover rather than lost.
      assert html =~ "read from or written to the prompt cache"
    end

    test "an account that has done nothing this month says so", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Nothing yet this month."
      # Tokens with nothing behind them read as a dash. (Asserting the dash
      # itself would pass on the hint text's em-dash, so pin the absence.)
      refute html =~ "0 / 0"
    end

    # Usage events are best-effort, so turns can exist with no events behind
    # them. "Nothing yet" over a populated tile reads as a bug.
    test "it does not say nothing while a tile says something", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(turn, %{"input" => 10, "output" => 2})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "Nothing yet this month."
    end

    test "the billing link is there only when billing is on", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      if Fountain.Billing.enabled?() do
        assert html =~ ~p"/account/billing"
      else
        refute html =~ ~s|href="/account/billing"|
      end
    end
  end

  test "a deployment with no conversations app links to none of it", %{conn: conn, user: user} do
    Application.put_env(:fountain, :conversations_app_url, "")
    insert_agent(user_id: user.id)
    insert_conversation(user_id: user.id)

    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    refute html =~ "apps.test/convs"
    # And it does not ask for a conversation it has nowhere to start.
    refute html =~ "Start one"
  end
end
