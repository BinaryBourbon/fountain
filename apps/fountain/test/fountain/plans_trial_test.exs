defmodule Fountain.PlansTrialTest do
  @moduledoc """
  A trial is a sample, not a smaller subscription: while it runs the `trial`
  plan's numbers apply, not those of the tier being trialled.

  `async: false` — several of these move `:billing_enabled`, which is global.
  """
  use Fountain.DataCase, async: false

  alias Fountain.{Plans, Quotas}

  setup do
    previous = Application.get_env(:fountain, :billing_enabled)
    Application.put_env(:fountain, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :billing_enabled, previous) end)
    :ok
  end

  defp with_billing_off(fun) do
    Application.put_env(:fountain, :billing_enabled, false)
    fun.()
  after
    Application.put_env(:fountain, :billing_enabled, true)
  end

  describe "the trial plan" do
    # `<=`, not `<`: the trial matches Solo's capacity rather than sitting
    # under it. What must never happen is the trial being *larger* than a plan
    # somebody pays for, which would make converting a downgrade — and since
    # the public caps climb strictly (`plans_test.exs`), levelling with the
    # cheapest still leaves it strictly below Team and Scale.
    test "is never larger than any public plan, on any axis" do
      trial = Plans.fetch!("trial")

      for plan <- Plans.public() do
        assert trial.concurrent_sandboxes <= plan.concurrent_sandboxes
        assert trial.included_credit_cents <= plan.included_credit_cents
        assert trial.team_contacts <= plan.team_contacts
      end
    end

    # The one axis that still separates the trial from the plan directly above
    # it. If this ever ties too, a free trial and a paid Solo are the same
    # thing with a clock on one of them.
    test "carries strictly fewer contacts than the cheapest public plan" do
      cheapest = Plans.public() |> List.first()
      assert Plans.fetch!("trial").team_contacts < cheapest.team_contacts
    end

    # The whole reason it exists: converting has to hand the customer something
    # the same day, which is also what makes the portal's `end_trial` setting
    # coherent rather than punitive.
    test "is never offered for sale, and sorts below everything" do
      trial = Plans.fetch!("trial")

      refute trial.public?
      refute "trial" in Plans.public_slugs()
      assert Enum.all?(Plans.public(), &Plans.upgrade?(trial, &1))
      assert trial.monthly_cents == 0
    end

    test "holds the $5-per-slot ratio the other plans do" do
      trial = Plans.fetch!("trial")
      assert trial.included_credit_cents == trial.concurrent_sandboxes * 500
    end

    # `users.plan` is written only from the Stripe price on a subscription and
    # there is no trial price, so the column cannot hold "trial" — and nothing
    # should be able to put it there by hand either. Keeping it out of
    # `slugs/0` is what stops the changeset, the admin selector, `change_plan/3`
    # and the OpenAPI enums each having to know separately.
    test "is derived, never stored" do
      refute "trial" in Plans.slugs()
      refute Plans.known?("trial")

      assert %Ecto.Changeset{valid?: false} =
               Fountain.Accounts.User.plan_changeset(%Fountain.Accounts.User{}, %{plan: "trial"})

      # Still reachable in the catalog, which is how `effective/1` returns it.
      assert Plans.fetch!("trial").slug == "trial"
      assert Enum.any?(Plans.all(), &(&1.slug == "trial"))
    end

    # A slug that cannot be stored must not be a DEFAULT_PLAN either, or a
    # self-hoster could cap their whole instance at two sandboxes by typo.
    test "cannot be set as DEFAULT_PLAN" do
      previous = Application.get_env(:fountain, :default_plan)
      Application.put_env(:fountain, :default_plan, "trial")
      on_exit(fn -> Application.put_env(:fountain, :default_plan, previous) end)

      assert Plans.default_slug() == "solo"
    end
  end

  describe "effective/1" do
    test "a trialing account gets the trial's numbers, not its tier's" do
      user = %{plan: "scale", subscription_status: "trialing"}

      assert Plans.effective(user).slug == "trial"
      assert Plans.concurrent_sandboxes(user) == 2
      assert Plans.included_credit_cents(user) == 1000
      assert Plans.team_contacts(user) == 0
    end

    # `resolve/1` still answers "what will they pay for", which is what the
    # picker, the price id and the billing page's plan name all need.
    test "resolve/1 keeps naming the tier the trial converts into" do
      user = %{plan: "scale", subscription_status: "trialing"}

      assert Plans.resolve(user).slug == "scale"
      assert Plans.monthly_cents(user) == Plans.fetch!("scale").monthly_cents
    end

    test "every other status gets the tier" do
      for status <- ~w(active past_due canceled comped) do
        user = %{plan: "team", subscription_status: status}
        assert Plans.effective(user).slug == "team", "status=#{status}"
        assert Plans.concurrent_sandboxes(user) == 5
      end
    end

    # A slug carries no status, so it cannot be trial-aware. Pinned because
    # `turn_hour_allowance/2` passed one and silently handed trialing accounts
    # the paid allowance.
    test "a bare slug is the plan's own number, trial or not" do
      assert Plans.concurrent_sandboxes("scale") == 10
      assert Plans.included_credit_cents("scale") == 5000
    end

    # `subscription_status` defaults to "trialing" in the schema, so without
    # this guard every self-hosted account would be silently capped at two
    # sandboxes — for someone paying their own provider bill.
    test "billing disabled means no trial limits at all" do
      user = %{plan: "scale", subscription_status: "trialing"}

      with_billing_off(fn ->
        assert Plans.effective(user).slug == "scale"
        assert Plans.concurrent_sandboxes(user) == 10
      end)
    end

    test "billing disabled with no plan follows DEFAULT_PLAN, not the trial" do
      user = %{plan: nil, subscription_status: "trialing"}

      with_billing_off(fn ->
        assert Plans.effective(user).slug == Plans.default_slug()
      end)
    end
  end

  describe "the cap actually enforced" do
    # The cap is the balance's, not the plan's (ADR 0031); the plan tests
    # above are about what a trial is, and this one is about what it may run.
    test "a trialing account with nothing in its balance gets the floor, whatever its tier" do
      user = insert_verified_user(plan: "scale")
      assert Quotas.sandbox_limit(user.id) == Quotas.default_limit()
      assert Quotas.sandbox_limit_for(reload(user)) == Quotas.default_limit()
    end

    test "an operator override beats the balance, in both directions" do
      up = insert_verified_user(plan: "solo")
      {:ok, up} = Fountain.Accounts.update_sandbox_limit(up, 25)
      assert Quotas.sandbox_limit(up.id) == 25

      down = insert_verified_user(plan: "scale")
      {:ok, down} = Fountain.Accounts.update_sandbox_limit(down, 0)
      assert Quotas.sandbox_limit(down.id) == 0
    end
  end

  defp reload(user), do: Fountain.Repo.get!(Fountain.Accounts.User, user.id)

  defp activate(user) do
    user
    |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "active"})
    |> Fountain.Repo.update()
  end
end
