defmodule Fountain.PlansTest do
  use ExUnit.Case, async: false

  alias Fountain.Plans

  setup do
    price_ids = Application.get_env(:fountain, :stripe_price_ids)
    legacy = Application.get_env(:fountain, :stripe_price_id)
    default = Application.get_env(:fountain, :default_plan)

    on_exit(fn ->
      Application.put_env(:fountain, :stripe_price_ids, price_ids)
      Application.put_env(:fountain, :stripe_price_id, legacy)

      case default do
        nil -> Application.delete_env(:fountain, :default_plan)
        value -> Application.put_env(:fountain, :default_plan, value)
      end
    end)

    Application.put_env(:fountain, :stripe_price_ids, %{
      "solo" => "price_solo",
      "team" => "price_team",
      "scale" => "price_scale",
      "contact" => "price_contact"
    })

    :ok
  end

  describe "the catalog" do
    # `trial` sorts below `legacy`, which is what makes every real plan an
    # upgrade from it and keeps it out of every "switch to" list.
    test "is ordered cheapest first, with the two closed plans before them" do
      assert Enum.map(Plans.all(), & &1.slug) == ~w(trial legacy solo team scale)
    end

    test "public/0 hides the closed plan" do
      assert Enum.map(Plans.public(), & &1.slug) == ~w(solo team scale)
    end

    # Concurrency is the axis the tiers are sold on, so a ladder that does not
    # climb is a pricing bug, not a cosmetic one.
    test "each public plan allows strictly more concurrency than the one below" do
      caps = Enum.map(Plans.public(), & &1.concurrent_sandboxes)
      assert caps == Enum.sort(caps)
      assert length(Enum.uniq(caps)) == length(caps)
    end

    # The allowance is derived, not chosen per tier (#1016). Asserting the
    # ratio is what makes breaking it a deliberate act rather than a typo in
    # one of four near-identical literals.
    test "included turn hours are 20 per concurrent slot, on every plan" do
      for plan <- Plans.all() do
        assert plan.included_turn_hours == plan.concurrent_sandboxes * 20,
               "#{plan.slug} carries #{plan.included_turn_hours} hours for " <>
                 "#{plan.concurrent_sandboxes} slots"
      end
    end

    test "the closed plan carries Team's hours, as it carries Team's capacity" do
      assert Plans.fetch!("legacy").included_turn_hours ==
               Plans.fetch!("team").included_turn_hours
    end

    test "each public plan includes strictly more hours than the one below" do
      hours = Enum.map(Plans.public(), & &1.included_turn_hours)
      assert hours == Enum.sort(hours)
      assert length(Enum.uniq(hours)) == length(hours)
    end

    test "each public plan costs strictly more than the one below" do
      prices = Enum.map(Plans.public(), & &1.monthly_cents)
      assert prices == Enum.sort(prices)
      assert length(Enum.uniq(prices)) == length(prices)
    end

    # Not an entitlement, but it still has to climb: a bigger plan allowing
    # fewer teammate contacts than a smaller one would be a pricing bug that
    # only shows up when somebody upgrades and loses a number.
    test "the contact ceiling climbs with the plan, and starts above zero" do
      ceilings = Enum.map(Plans.public(), & &1.team_contacts)
      assert ceilings == Enum.sort(ceilings)
      assert length(Enum.uniq(ceilings)) == length(ceilings)
      assert Enum.min(ceilings) >= 1
    end

    # Written out rather than derived, so moving a number in the catalog is a
    # deliberate edit here too — these are what customers are sold.
    test "the ceilings are the ones we sell" do
      assert Plans.team_contacts("solo") == 1
      assert Plans.team_contacts("team") == 3
      assert Plans.team_contacts("scale") == 10
    end

    # The grandfathering promise: nobody's cap fell when the tiers landed.
    test "legacy carries Team's capacity at the old flat price" do
      legacy = Plans.fetch!("legacy")
      team = Plans.fetch!("team")

      assert legacy.concurrent_sandboxes == team.concurrent_sandboxes
      # Both axes, not just concurrency: "Team's capacity" has to keep meaning
      # that when a ceiling moves, or a legacy account silently drifts off the
      # plan it was promised.
      assert legacy.team_contacts == team.team_contacts
      assert legacy.monthly_cents == Plans.fetch!("solo").monthly_cents
      refute legacy.public?
    end
  end

  describe "lookup" do
    test "known?/1 accepts only a slug in the catalog" do
      assert Plans.known?("team")
      refute Plans.known?("enterprise")
      refute Plans.known?(nil)
      refute Plans.known?(:team)
    end

    test "get/1 answers nil for anything that is not a known slug" do
      assert Plans.get("scale").name == "Scale"
      assert Plans.get("enterprise") == nil
      assert Plans.get(nil) == nil
    end

    # fetch!/1 is for tests and mix tasks, where a typo should stop the run
    # rather than silently resolve to the default.
    test "fetch!/1 raises on an unknown slug" do
      assert_raise ArgumentError, ~r/unknown plan/, fn -> Plans.fetch!("enterprise") end
    end

    # Storable slugs, so `legacy` is in and `trial` is not: a `users.plan` row
    # can hold the closed flat plan but never the derived trial one.
    test "slugs/0 lists every plan a row can hold, including the closed one" do
      assert Enum.sort(Plans.slugs()) == Enum.sort(~w(solo team scale legacy))
    end

    # The distinction is load-bearing: `slugs/0` is what a stored row may hold
    # and still includes the closed plan, while `public_slugs/0` is what a
    # request may name. Publishing `legacy` on the checkout endpoint would
    # advertise a price Checkout cannot honour.
    test "public_slugs/0 excludes the closed plan" do
      assert Plans.public_slugs() == ~w(solo team scale)
      refute "legacy" in Plans.public_slugs()
    end
  end

  describe "entitlement readers" do
    test "read from a plan, a slug or a user alike" do
      plan = Plans.fetch!("scale")

      for subject <- [plan, "scale", %{plan: "scale"}] do
        assert Plans.concurrent_sandboxes(subject) == plan.concurrent_sandboxes
        assert Plans.included_turn_hours(subject) == plan.included_turn_hours
        assert Plans.team_contacts(subject) == plan.team_contacts
        assert Plans.monthly_cents(subject) == plan.monthly_cents
      end
    end

    test "the contact add-on has a display price, overridable by config" do
      assert Plans.contact_monthly_cents() == 500

      Application.put_env(:fountain, :stripe_contact_price_cents, 1200)
      on_exit(fn -> Application.delete_env(:fountain, :stripe_contact_price_cents) end)

      assert Plans.contact_monthly_cents() == 1200
    end

    test "the contact add-on price id is nil when unconfigured" do
      Application.put_env(:fountain, :stripe_price_ids, %{"solo" => "price_solo"})
      assert Plans.contact_price_id() == nil
    end
  end

  describe "resolve/1" do
    test "takes a user, a slug, a plan or nil" do
      assert Plans.resolve("team").slug == "team"
      assert Plans.resolve(%{plan: "scale"}).slug == "scale"
      assert Plans.resolve(Plans.fetch!("solo")).slug == "solo"
      assert Plans.resolve(nil).slug == Plans.default_slug()
    end

    # A row holding a retired slug must tighten to a known plan rather than
    # taking down every request that reads it.
    test "an unknown slug resolves to the default instead of raising" do
      assert Plans.resolve("enterprise-2019").slug == Plans.default_slug()
      assert Plans.resolve(%{plan: nil}).slug == Plans.default_slug()
    end

    test "DEFAULT_PLAN moves what nil resolves to" do
      Application.put_env(:fountain, :default_plan, "scale")
      assert Plans.resolve(nil).slug == "scale"
      assert Plans.concurrent_sandboxes(nil) == Plans.fetch!("scale").concurrent_sandboxes
    end

    test "an unusable DEFAULT_PLAN falls back to solo rather than crashing" do
      Application.put_env(:fountain, :default_plan, "nonsense")
      assert Plans.default_slug() == "solo"
    end
  end

  describe "price ids" do
    test "price_id/1 reads the configured map" do
      assert Plans.price_id("team") == "price_team"
      assert Plans.price_id(Plans.fetch!("scale")) == "price_scale"
    end

    test "legacy falls back to the original single price variable" do
      Application.put_env(:fountain, :stripe_price_id, "price_old_flat")
      assert Plans.price_id("legacy") == "price_old_flat"
    end

    test "a plan with no price id has none — it simply cannot be subscribed to" do
      Application.put_env(:fountain, :stripe_price_ids, %{"team" => "price_team"})
      Application.put_env(:fountain, :stripe_price_id, nil)

      assert Plans.price_id("solo") == nil
      assert Plans.price_id("legacy") == nil
    end

    # `get_env(key, %{})` hands back the default only when the key is ABSENT.
    # A key explicitly holding nil is a different state, and reading it as a
    # map raised BadMapError on the marketing page — which is the first thing
    # a visitor sees.
    test "a price-id config of nil reads as no prices, not as a crash" do
      Application.put_env(:fountain, :stripe_price_ids, nil)
      Application.put_env(:fountain, :stripe_price_id, nil)

      assert Plans.price_id("solo") == nil
      assert Plans.contact_price_id() == nil
      assert Plans.slug_for_price_id("price_anything") == nil
    end

    test "slug_for_price_id/1 maps a price back to its plan" do
      assert Plans.slug_for_price_id("price_scale") == "scale"
    end

    # The webhook leans on this: nil must mean "leave the stored plan alone",
    # so the add-on price must never look like a tier.
    test "the contact add-on price maps to no plan" do
      assert Plans.slug_for_price_id("price_contact") == nil
      assert Plans.contact_price_id() == "price_contact"
    end

    test "an unknown price maps to no plan" do
      assert Plans.slug_for_price_id("price_someone_elses") == nil
      assert Plans.slug_for_price_id(nil) == nil
      assert Plans.slug_for_price_id("") == nil
    end
  end

  describe "upgrade?/2" do
    test "compares position on the ladder" do
      assert Plans.upgrade?("solo", "team")
      assert Plans.upgrade?("team", "scale")
      refute Plans.upgrade?("scale", "solo")
      refute Plans.upgrade?("team", "team")
    end

    # This is what makes the closed plan upgrade-only: every public plan is
    # above it, so nothing offers a move back onto a price nobody can buy.
    test "every public plan is an upgrade from legacy" do
      assert Enum.all?(Plans.public(), &Plans.upgrade?("legacy", &1))
      refute Enum.any?(Plans.public(), &Plans.upgrade?(&1, "legacy"))
    end
  end

  describe "format_usd/1" do
    test "drops the cents on a whole dollar amount" do
      assert Plans.format_usd(2900) == "$29"
      assert Plans.format_usd(19_900) == "$199"
    end

    test "keeps them otherwise" do
      assert Plans.format_usd(2950) == "$29.50"
      assert Plans.format_usd(99) == "$0.99"
    end
  end
end
