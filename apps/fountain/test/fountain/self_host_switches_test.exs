defmodule Fountain.SelfHostSwitchesTest do
  @moduledoc """
  The two switches a self-hoster needs and did not have.

  ADR 0006 made the subscription gate a product invariant, which is right for
  the hosted instance and is a lock with no key on a self-hosted one — the ADR
  itself notes the reversal costs "one line", but that line was a source patch.

  Registration was open to the world with no way to close it. On the hosted side
  that matters too: every signup consumes the platform Sprites token, and
  production took 188 signups in two weeks with a 1% activation rate.
  """

  use Fountain.DataCase, async: false

  alias Fountain.{Accounts, Billing}

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  # The minimum a :prod evaluation of runtime.exs demands (the same set
  # otel_config_test.exs uses).
  @required_release_env %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "RESEND_API_KEY" => "re_test_key",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  @switch_vars ~w(BILLING_ENABLED REGISTRATION_ENABLED REGISTRATION_ALLOWED_EMAIL_DOMAINS STRIPE_WEBHOOK_SECRET)

  defp read_prod_config(extra) do
    previous = System.get_env()

    try do
      for k <- @switch_vars, do: System.delete_env(k)

      @required_release_env
      |> Map.put(
        "MASTER_SECRETS_KEY",
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      )
      |> Map.merge(extra)
      |> System.put_env()

      Config.Reader.read!(@runtime_exs, env: :prod)
    after
      System.put_env(previous)
      for k <- @switch_vars, not Map.has_key?(previous, k), do: System.delete_env(k)
    end
  end

  defp with_env(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp cancelled_user do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> Accounts.User.billing_changeset(%{subscription_status: "canceled"})
      |> Fountain.Repo.update()

    user
  end

  describe "the env-var side, read the way the release config provider does" do
    # runtime.exs skips the BILLING_ENABLED mapping under :test (the suite
    # pins :billing_enabled in config/test.exs), and the domain-list tests
    # below inject the parsed application env directly — so without these,
    # nothing fails if the runtime.exs default flips or the parsing breaks.

    test "BILLING_ENABLED defaults off — a bare self-host must not lock itself out (#336)" do
      cfg = read_prod_config(%{})
      assert cfg[:fountain][:billing_enabled] == false
    end

    test "BILLING_ENABLED=true opts the hosted deployment in" do
      # Billing on requires the webhook secret at boot (#416), so supply one.
      cfg =
        read_prod_config(%{
          "BILLING_ENABLED" => "true",
          "STRIPE_WEBHOOK_SECRET" => "whsec_test"
        })

      assert cfg[:fountain][:billing_enabled] == true
    end

    test "REGISTRATION_ALLOWED_EMAIL_DOMAINS is split, trimmed and downcased" do
      cfg =
        read_prod_config(%{
          "REGISTRATION_ALLOWED_EMAIL_DOMAINS" => "Example.com, BETA.org ,gamma.io,"
        })

      assert cfg[:fountain][:registration_allowed_email_domains] ==
               ["example.com", "beta.org", "gamma.io"]
    end

    test "unset or empty REGISTRATION_ALLOWED_EMAIL_DOMAINS means no domain filter" do
      assert read_prod_config(%{})[:fountain][:registration_allowed_email_domains] == []

      assert read_prod_config(%{"REGISTRATION_ALLOWED_EMAIL_DOMAINS" => ""})[:fountain][
               :registration_allowed_email_domains
             ] == []
    end

    test "REGISTRATION_ENABLED=false closes signup at the config level" do
      assert read_prod_config(%{"REGISTRATION_ENABLED" => "false"})[:fountain][
               :registration_enabled
             ] == false

      assert read_prod_config(%{})[:fountain][:registration_enabled] == true
    end
  end

  describe "BILLING_ENABLED" do
    test "the gate is enforced by default" do
      assert {:error, :subscription_required} = Billing.check_active(cancelled_user())
    end

    test "disabling it lets a cancelled account through" do
      user = cancelled_user()

      with_env([billing_enabled: false], fn ->
        assert :ok = Billing.check_active(user)
      end)
    end

    test "assert_active!/1 follows the same switch" do
      user = cancelled_user()

      with_env([billing_enabled: false], fn ->
        assert :ok = Billing.assert_active!(user)
      end)

      assert_raise Billing.SubscriptionRequiredError, fn ->
        Billing.assert_active!(user)
      end
    end

    test "a conversation can start with billing disabled" do
      # The end-to-end point: the gate is checked in the context, so the switch
      # has to reach there and not just the controller.
      user = cancelled_user()
      agent = insert_agent(user_id: user.id)

      with_env([billing_enabled: false], fn ->
        Mimic.stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec ->
          {:ok, spawn(fn -> :ok end)}
        end)

        assert {:ok, _} =
                 Fountain.Conversations.start_conversation(%{
                   "agent_id" => agent.id,
                   "user_id" => user.id
                 })
      end)
    end
  end

  describe "BILLING_ENABLED=false silences the Stripe sync (#335)" do
    # Every signup enqueued a StripeCustomerSync that 401ed through all five
    # attempts — dead Oban jobs and error noise a self-hoster has no way to
    # know are benign.

    test "enqueue is a no-op" do
      user = insert_verified_user()

      with_env([billing_enabled: false], fn ->
        assert {:ok, :billing_disabled} = Fountain.Workers.StripeCustomerSync.enqueue(user)

        refute_enqueued(worker: Fountain.Workers.StripeCustomerSync)
      end)
    end

    test "an already-queued job completes without touching Stripe" do
      # The flag can flip off with jobs still in the queue.
      user = insert_verified_user()
      Mimic.reject(&Stripe.Customer.create/1)

      with_env([billing_enabled: false], fn ->
        assert :ok =
                 perform_job(Fountain.Workers.StripeCustomerSync, %{user_id: user.id})
      end)

      refute Fountain.Repo.reload(user).stripe_customer_id
    end

    test "enqueue still works when billing is on" do
      user = insert_verified_user()

      assert {:ok, %Oban.Job{}} = Fountain.Workers.StripeCustomerSync.enqueue(user)
      assert_enqueued(worker: Fountain.Workers.StripeCustomerSync)
    end
  end

  describe "REGISTRATION_ENABLED" do
    test "registration is open by default" do
      assert :ok = Accounts.registration_allowed?("someone@example.com")
    end

    test "closing it refuses new accounts" do
      with_env([registration_enabled: false], fn ->
        assert {:error, :registration_closed} =
                 Accounts.registration_allowed?("someone@example.com")

        assert {:error, :registration_closed} =
                 Accounts.register_user(%{
                   "email" => "blocked@example.com",
                   "password" => "password123"
                 })
      end)
    end

    test "closing it does not affect existing accounts" do
      user = insert_verified_user()

      with_env([registration_enabled: false], fn ->
        assert {:ok, ^user} = Accounts.authenticate_user(user.email, "password123")
      end)
    end
  end

  describe "REGISTRATION_ALLOWED_EMAIL_DOMAINS" do
    test "an empty list allows any domain" do
      assert :ok = Accounts.registration_allowed?("anyone@anywhere.test")
    end

    test "a configured list admits only those domains" do
      with_env([registration_allowed_email_domains: ["example.com"]], fn ->
        assert :ok = Accounts.registration_allowed?("someone@example.com")

        assert {:error, :email_domain_not_allowed} =
                 Accounts.registration_allowed?("someone@elsewhere.com")
      end)
    end

    test "matching is case-insensitive" do
      with_env([registration_allowed_email_domains: ["example.com"]], fn ->
        assert :ok = Accounts.registration_allowed?("Someone@EXAMPLE.com")
      end)
    end

    test "a malformed address is refused rather than admitted" do
      with_env([registration_allowed_email_domains: ["example.com"]], fn ->
        assert {:error, :email_domain_not_allowed} = Accounts.registration_allowed?("no-at-sign")
        assert {:error, :email_domain_not_allowed} = Accounts.registration_allowed?(nil)
      end)
    end
  end

  describe "OAuth signup" do
    test "is gated too, not just the forms" do
      # The path most likely to be missed by a controller-level check: an
      # unrecognised OAuth identity creates an account.
      with_env([registration_enabled: false], fn ->
        assert {:error, :registration_closed} =
                 Accounts.upsert_oauth_user(
                   "github",
                   "gh-#{System.unique_integer([:positive])}",
                   %{
                     "email" => "newcomer@example.com"
                   }
                 )
      end)
    end

    test "an existing user can still sign in when registration is closed" do
      user = insert_verified_user()
      uid = "gh-#{System.unique_integer([:positive])}"
      {:ok, _, :existing} = Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})

      with_env([registration_enabled: false], fn ->
        assert {:ok, _user, :existing} =
                 Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})
      end)
    end
  end
end
