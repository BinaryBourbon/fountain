defmodule Fountain.Credits.RentTest do
  @moduledoc """
  Rent a month up front, the anniversary, and the seven-day grace (ADR 0030
  decision 4). `async: false`: the switches and prices are global config.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Credits
  alias Fountain.Credits.Rent
  alias Fountain.Repo
  alias Fountain.Team.Contact
  alias Fountain.Workers.CreditsEmail

  @since ~U[2026-07-01 00:00:00Z]

  defp switch(opts) do
    cfg = Application.get_env(:fountain, :credits)
    Application.put_env(:fountain, :credits, Keyword.merge(cfg, opts))
    on_exit(fn -> Application.put_env(:fountain, :credits, cfg) end)
  end

  defp contact(user, attrs \\ %{}) do
    agent = insert_agent(user_id: user.id)

    %Contact{}
    |> Contact.changeset(%{
      user_id: user.id,
      agent_id: agent.id,
      email_address: "ada@agentmail.to",
      email_inbox_id: "inbox_1",
      phone_number: "+15551234567",
      phone_number_id: "num_1"
    })
    |> Repo.insert!()
    |> Ecto.Changeset.change(Map.to_list(attrs))
    |> Repo.update!()
  end

  test "no rent when no price is set" do
    switch([])
    assert Rent.month_cents() == 0
    refute Rent.charging?()
    user = insert_empty_user()
    assert {:ok, :free} = Rent.charge(contact(user), ~U[2026-08-01 00:00:00Z])
    assert %{charged: 0, reminded: 0, released: 0} = Rent.collect(now: ~U[2026-08-10 00:00:00Z])
  end

  test "add_month clamps to the shorter month" do
    assert Rent.add_month(~U[2026-01-31 12:00:00Z]) == ~U[2026-02-28 12:00:00Z]
    assert Rent.add_month(~U[2026-12-15 00:00:00Z]) == ~U[2027-01-15 00:00:00Z]
  end

  describe "with a price and a funded account" do
    setup do
      switch(number_cents: 300, inbox_cents: 200)
      :ok
    end

    # The opening credit ($10) funds two months of rent.
    test "charge takes a month up front, once per period, and moves the paid-through date" do
      user = insert_verified_user()
      # $5 opening credit plus $5 bought: one month of rent, with $5 to spare.
      {:ok, _} = Credits.grant(user.id, 500, "purchase", idempotency_key: "top-up")
      c = contact(user)
      start = ~U[2026-08-05 10:00:00Z]

      assert {:ok, %Contact{rent_paid_through: ~U[2026-09-05 10:00:00Z]}} = Rent.charge(c, start)
      assert Credits.balance(user.id) == 500
      [entry] = Credits.list_entries(user.id) |> Enum.filter(&(&1.reason == "burn_rent"))
      assert entry.resource_id == c.id

      assert {:ok, :duplicate, _} = Rent.charge(c, start)
      assert Credits.balance(user.id) == 500
    end

    test "collect charges every contact whose month is up, starting a never-charged one now" do
      user = insert_verified_user()
      {:ok, _} = Credits.grant(user.id, 500, "purchase", idempotency_key: "top-up")
      fresh = contact(user)
      due = contact(user, %{rent_paid_through: ~U[2026-08-01 00:00:00Z]})
      paid = contact(user, %{rent_paid_through: ~U[2026-09-01 00:00:00Z]})

      assert %{charged: 2} = Rent.collect(now: ~U[2026-08-10 00:00:00Z])
      assert Repo.reload!(fresh).rent_paid_through == ~U[2026-09-10 00:00:00Z]
      assert Repo.reload!(due).rent_paid_through == ~U[2026-09-01 00:00:00Z]
      assert Repo.reload!(paid).rent_paid_through == ~U[2026-09-01 00:00:00Z]
      # $10 held, two months charged.
      assert Credits.balance(user.id) == 0

      assert %{charged: 0} = Rent.collect(now: ~U[2026-08-11 00:00:00Z])
    end
  end

  describe "with enforcement on" do
    setup do
      switch(enforce: true, number_cents: 300, inbox_cents: 200)
      :ok
    end

    test "a comped account is never refused rent, and never enters the grace" do
      {:ok, user} = Fountain.Billing.comp_account(insert_empty_user())
      assert :ok = Rent.check_provision(user.id)
      c = contact(user, %{rent_paid_through: ~U[2026-08-01 00:00:00Z]})

      assert {:ok, %Contact{rent_due_at: nil}} =
               Rent.charge(c, ~U[2026-08-01 00:00:00Z], now: ~U[2026-08-02 00:00:00Z])

      assert Credits.balance(user.id) == -500
    end

    test "provisioning is refused below a month, and allowed at it" do
      user = insert_empty_user()
      assert {:error, :insufficient_credits} = Rent.check_provision(user.id)
      {:ok, _} = Credits.grant(user.id, 500, "purchase", idempotency_key: "p")
      assert :ok = Rent.check_provision(user.id)
    end

    test "a month already paid is a duplicate whatever the balance is now (#1126)" do
      user = insert_empty_user()
      {:ok, _} = Credits.grant(user.id, 500, "purchase", idempotency_key: "p")
      c = contact(user, %{rent_paid_through: ~U[2026-08-01 00:00:00Z]})
      period = ~U[2026-08-01 00:00:00Z]

      assert {:ok, %Contact{}} = Rent.charge(c, period, now: ~U[2026-08-02 00:00:00Z])
      assert Credits.balance(user.id) == 0

      assert {:ok, :duplicate, %Contact{rent_due_at: nil} = c} =
               Rent.charge(Repo.reload!(c), period, now: ~U[2026-08-03 00:00:00Z])

      assert c.rent_paid_through == ~U[2026-09-01 00:00:00Z]
      assert Repo.reload!(c).rent_due_at == nil
    end

    test "a short balance leaves the month unpaid and starts the grace" do
      user = insert_empty_user()
      c = contact(user, %{rent_paid_through: ~U[2026-08-01 00:00:00Z]})
      now = ~U[2026-08-02 00:00:00Z]

      assert {:error, :insufficient_credits} = Rent.charge(c, ~U[2026-08-01 00:00:00Z], now: now)
      assert Repo.reload!(c).rent_due_at == now
      assert Credits.balance(user.id) == 0
    end

    test "grace: reminders on day 0, 3 and 6; a top-up pays; release on day 7" do
      user = insert_empty_user()
      c = contact(user, %{rent_paid_through: ~U[2026-08-01 00:00:00Z]})
      day0 = ~U[2026-08-02 00:00:00Z]

      # Day 0: the sweep cannot charge, stamps the grace, and reminds in the
      # same pass.
      assert %{charged: 0, reminded: 1, released: 0} = Rent.collect(now: day0)
      assert Repo.reload!(c).rent_due_at == day0

      assert_enqueued(
        worker: CreditsEmail,
        args: %{"email" => "rent_due", "contact_id" => c.id, "days_left" => 7}
      )

      # Day 1 and 2: nothing.
      assert %{reminded: 0, released: 0} = Rent.collect(now: DateTime.add(day0, 86_400, :second))
      # Day 3.
      assert %{reminded: 1} = Rent.collect(now: DateTime.add(day0, 3 * 86_400 + 60, :second))

      assert_enqueued(
        worker: CreditsEmail,
        args: %{"email" => "rent_due", "contact_id" => c.id, "days_left" => 4}
      )

      # Day 6: nothing sent yet — then a top-up lands; the sweep pays and clears the grace.
      {:ok, _} = Credits.grant(user.id, 500, "purchase", idempotency_key: "p")

      assert %{reminded: 0, released: 0} =
               Rent.collect(now: DateTime.add(day0, 6 * 86_400, :second))

      assert %Contact{rent_due_at: nil, rent_paid_through: ~U[2026-09-01 00:00:00Z]} =
               Repo.reload!(c)

      assert Credits.balance(user.id) == 0
    end

    test "day 7 with no top-up releases the contact" do
      user = insert_empty_user()

      c =
        contact(user, %{
          rent_paid_through: ~U[2026-08-01 00:00:00Z],
          rent_due_at: ~U[2026-08-02 00:00:00Z]
        })

      test = self()

      Mimic.copy(Fountain.Team.Comms)

      Mimic.stub(Fountain.Team.Comms, :release_contact, fn user_id, agent_id, opts ->
        send(test, {:released, user_id, agent_id, opts[:actor]})
        :ok
      end)

      assert %{released: 0} = Rent.collect(now: ~U[2026-08-08 23:00:00Z])
      assert %{released: 1} = Rent.collect(now: ~U[2026-08-09 00:00:01Z])
      assert_receive {:released, uid, aid, "system:credit_rent"}
      assert uid == user.id and aid == c.agent_id
    end
  end

  test "the rent email is dropped once the contact is paid or gone" do
    switch(number_cents: 300, inbox_cents: 200)
    user = insert_empty_user()
    c = contact(user, %{rent_due_at: ~U[2026-08-02 00:00:00Z]})
    test = self()

    stub(Fountain.Mailer, :deliver, fn email ->
      send(test, {:sent, email.subject})
      {:ok, %{}}
    end)

    job = %Oban.Job{
      args: %{"user_id" => user.id, "email" => "rent_due", "contact_id" => c.id, "days_left" => 4}
    }

    assert :ok = CreditsEmail.perform(job)
    assert_receive {:sent, "Your teammate's number will be released in 4 days"}

    c |> Ecto.Changeset.change(rent_due_at: nil) |> Repo.update!()
    assert :ok = CreditsEmail.perform(job)
    refute_receive {:sent, _}
  end
end
