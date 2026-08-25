defmodule Fountain.CreditsEnforcementTest do
  @moduledoc """
  The soft stop (ADR 0030 decision 6), the renewal grant, the admin grant
  and the runway emails. `async: false`: the two switches are global config.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic
  use Oban.Testing, repo: Fountain.Repo

  alias Fountain.Accounts
  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Conversations
  alias Fountain.Credits
  alias Fountain.Quotas
  alias Fountain.Repo
  alias Fountain.Workers.CreditsEmail

  @since ~U[2026-07-01 00:00:00Z]

  defp switch(opts) do
    cfg = Application.get_env(:fountain, :credits)
    Application.put_env(:fountain, :credits, Keyword.merge(cfg, opts))
    on_exit(fn -> Application.put_env(:fountain, :credits, cfg) end)
  end

  # The opening credit burned away: an account that cannot spend.
  defp drained(user) do
    case Credits.balance(user.id) do
      0 ->
        user

      cents ->
        {:ok, _} = Credits.debit(user.id, cents, "burn_turn", idempotency_key: "drain-#{user.id}")
    end

    Repo.reload!(user)
  end

  defp subscriber(attrs \\ %{}) do
    user = insert_empty_user()

    {:ok, user} =
      user
      |> User.billing_changeset(Map.merge(%{stripe_customer_id: "cus_#{user.id}"}, attrs))
      |> Repo.update()

    user
  end

  describe "check_spend/1 with billing off" do
    test "a zero balance refuses nothing" do
      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
      user = subscriber()
      refute Credits.enforcing?()
      assert :ok = Credits.gate(user)
      assert :ok = Billing.check_spend(user)
    end
  end

  describe "check_spend/1 with billing on" do
    test "zero refuses, positive passes" do
      user = drained(subscriber())
      assert Credits.enforcing?()
      assert {:error, :insufficient_credits} = Billing.check_spend(user)
      assert {:error, :insufficient_credits} = Billing.check_spend(user.id)

      {:ok, _} = Credits.grant(user.id, 1, "purchase", idempotency_key: "p")
      assert :ok = Billing.check_spend(user.id)
    end

    test "billing off funds the ceiling, whatever the balance" do
      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
      assert Quotas.sandbox_limit(insert_empty_user().id) == Quotas.settings().cap_ceiling
    end

    test "comped and billing-off never refuse" do
      # No Stripe customer, so comping cancels nothing upstream.
      {:ok, comped} = Billing.comp_account(insert_empty_user())
      assert :ok = Billing.check_spend(comped)

      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
      assert :ok = Billing.check_spend(subscriber())
    end

    test "a conversation is refused at the door and no sandbox is allocated" do
      user = subscriber()
      agent = insert_agent(user_id: user.id)

      assert {:error, :insufficient_credits} =
               Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert Quotas.active_sandbox_counts() |> Map.get(user.id, 0) == 0
    end

    test "the reservation lock refuses under the same lock as the cap" do
      user = subscriber()
      test = self()

      assert {:error, :insufficient_credits} =
               Quotas.with_sandbox_reservation(user.id, [], fn ->
                 send(test, :ran)
                 {:ok, :never}
               end)

      refute_receive :ran

      {:ok, _} = Credits.grant(user.id, 1, "purchase", idempotency_key: "p")
      assert {:ok, :ran} = Quotas.with_sandbox_reservation(user.id, [], fn -> {:ok, :ran} end)
    end

    test "the API says 402 insufficient_credits", %{conn: conn} do
      user = subscriber()
      agent = insert_agent(user_id: user.id)
      {_rec, key} = insert_api_key(user)

      body =
        conn
        |> authed_with_key(key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/conversations", %{"agent_id" => agent.id})
        |> json_response(402)

      assert body["error"] == "insufficient_credits"
      assert body["upgrade_url"] == "/account/billing"
    end
  end

  describe "the admin grant" do
    setup do
      switch(pricing_since: @since, enforce: false)
      admin = insert_empty_user()
      {:ok, admin} = Accounts.update_user_role(admin, "admin")
      {_rec, key} = insert_api_key(admin)
      %{admin: admin, key: key}
    end

    test "adds a non-expiring grant_admin row and an admin event", %{
      conn: conn,
      key: key,
      admin: admin
    } do
      user = subscriber()

      body =
        conn
        |> authed_with_key(key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/admin/users/#{user.id}/credits", %{"cents" => 1500, "note" => "won dp_1"})
        |> json_response(200)

      assert body["data"]["credit_balance_cents"] == 1500
      [entry] = Credits.list_entries(user.id)
      assert entry.reason == "grant_admin" and is_nil(entry.expires_at)
      assert entry.metadata["note"] == "won dp_1"

      [ev] =
        Repo.all(Fountain.Audit.AdminEvent)
        |> Enum.filter(&(&1.event_type == "admin.credits.granted"))

      assert ev.actor_user_id == admin.id
      assert ev.metadata["cents"] == 1500

      body =
        conn
        |> authed_with_key(key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/admin/users/#{user.id}/credits", %{"cents" => -5})
        |> json_response(422)

      # The spec's `minimum: 1` refuses it before the action does.
      assert body["error"] == "invalid_request" or is_list(body["errors"])
    end
  end

  describe "runway emails" do
    setup do
      switch(pricing_since: @since, enforce: false)
      :ok
    end

    test "the runway line is 20% of the opening grant or $2" do
      assert CreditsEmail.runway_line(subscriber()) == 200
    end

    test "notify_after_burn enqueues low then exhausted, once each" do
      user = subscriber()

      {:ok, _} =
        Credits.grant(user.id, 1000, "grant_tier",
          idempotency_key: "g",
          expires_at: ~U[2099-01-01 00:00:00Z]
        )

      assert :ok = CreditsEmail.notify_after_burn(user.id)
      refute_enqueued(worker: CreditsEmail)

      {:ok, _} = Credits.debit(user.id, 850, "burn_turn", idempotency_key: "b1")
      assert :ok = CreditsEmail.notify_after_burn(user.id)

      assert_enqueued(
        worker: CreditsEmail,
        args: %{"user_id" => user.id, "email" => "credits_low"}
      )

      {:ok, _} = Credits.debit(user.id, 200, "burn_turn", idempotency_key: "b2")
      assert :ok = CreditsEmail.notify_after_burn(user.id)

      assert_enqueued(
        worker: CreditsEmail,
        args: %{"user_id" => user.id, "email" => "credits_exhausted"}
      )

      assert length(all_enqueued(worker: CreditsEmail)) == 2

      # Again: unique for thirty days.
      assert :ok = CreditsEmail.notify_after_burn(user.id)
      assert length(all_enqueued(worker: CreditsEmail)) == 2
    end

    test "the send is dropped when the state no longer holds" do
      user = subscriber()
      {:ok, _} = Credits.debit(user.id, 10, "burn_turn", idempotency_key: "b")
      test = self()

      stub(Fountain.Mailer, :deliver, fn email ->
        send(test, {:sent, email.subject})
        {:ok, %{}}
      end)

      assert :ok =
               CreditsEmail.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "email" => "credits_exhausted"}
               })

      assert_receive {:sent, "Your Fountain credit has run out"}

      {:ok, _} = Credits.grant(user.id, 5000, "purchase", idempotency_key: "p")

      assert :ok =
               CreditsEmail.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "email" => "credits_exhausted"}
               })

      assert :ok =
               CreditsEmail.perform(%Oban.Job{
                 args: %{"user_id" => user.id, "email" => "credits_low"}
               })

      refute_receive {:sent, _}
    end
  end
end
