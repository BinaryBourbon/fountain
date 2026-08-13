defmodule Fountain.Accounts.DeletionTest do
  @moduledoc """
  Closing an account.

  Two things have to hold at once and they pull against each other: everything
  belonging to the person has to go, and nothing may be destroyed while they are
  still being charged for it. Most of these tests are about the ordering that
  keeps both true.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  setup :set_mimic_global

  setup do
    stub(Fountain.SpritesClient, :get!, fn -> :client end)
    stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)
    stub(Sprites, :destroy, fn _handle -> :ok end)
    stub(Fountain.Conversations.ConversationServer, :whereis, fn _ -> nil end)
    :ok
  end

  defp billing_user(attrs) do
    user = insert_verified_user()

    {:ok, user} =
      user |> User.billing_changeset(attrs) |> Repo.update()

    user
  end

  describe "deletion confirmation email (#450)" do
    test "a verified account's deletion enqueues the confirmation, carrying the address" do
      user = insert_verified_user()

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert_enqueued(
        worker: Fountain.Workers.AccountEmail,
        args: %{kind: "deleted", email: user.email}
      )
    end

    test "an unverified account gets no confirmation — covers the pruner path" do
      # An address that never proved it was theirs gets no mail from us,
      # whoever triggered the deletion (UnverifiedAccountPruner included).
      user = insert_user()

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute_enqueued(worker: Fountain.Workers.AccountEmail)
    end
  end

  describe "what is removed" do
    test "the user and everything cascading from them" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent)
      {_key, _raw} = insert_api_key(user)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.get(User, user.id)
      refute Repo.get(Fountain.Agents.Agent, agent.id)
      refute Repo.get(Fountain.Environments.Environment, env.id)
      refute Repo.get(Fountain.Vaults.Vault, vault.id)
      refute Repo.get(Fountain.Conversations.Conversation, conv.id)
      assert Repo.all(from k in Fountain.Accounts.ApiKey, where: k.user_id == ^user.id) == []
    end

    test "the tenant's data encryption key" do
      # The crypto-shred. Every environment and vault secret is encrypted with
      # this key, so destroying it makes any ciphertext that outlives the
      # cascade — a row missed by a future schema change, a stray copy —
      # undecryptable rather than merely unreferenced.
      user = insert_verified_user()
      {:ok, _dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert Repo.exists?(
               from k in "user_data_keys", where: k.user_id == type(^user.id, :binary_id)
             )

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.exists?(
               from k in "user_data_keys", where: k.user_id == type(^user.id, :binary_id)
             )
    end

    test "usage events survive with no owner" do
      # NC-9: this FK had no on_delete at all, so a user delete failed outright
      # at the database level — which is why there was never a deletion path.
      # Nilify rather than cascade, so historical usage totals do not silently
      # change every time somebody closes an account.
      user = insert_verified_user()
      {:ok, event} = Fountain.Billing.record_usage(user.id, "turn_started", nil, nil)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert reloaded = Repo.get(Fountain.Billing.UsageEvent, event.id)
      assert reloaded.user_id == nil
    end
  end

  describe "sprites" do
    test "live sandboxes are destroyed" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      test = self()
      stub(Sprites, :destroy, fn {:handle, name} -> send(test, {:destroyed, name}) && :ok end)

      capture_log(fn -> assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(user) end)

      assert_received {:destroyed, name}
      assert name == sandbox.sprite_name
    end

    test "suspended sandboxes are destroyed too" do
      # Suspended is excluded from the quota but its sprite is alive at
      # sprites.dev — and deletion nilifies user_id, so a sprite missed here
      # is unfindable afterward, a permanent leak.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")

      test = self()
      stub(Sprites, :destroy, fn {:handle, name} -> send(test, {:destroyed, name}) && :ok end)

      capture_log(fn -> assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(user) end)

      assert_received {:destroyed, name}
      assert name == sandbox.sprite_name
    end

    test "already-terminal sandboxes are not touched again" do
      user = insert_verified_user()
      insert_sandbox(user_id: user.id, status: "terminated")
      reject(&Sprites.destroy/1)

      capture_log(fn -> assert {:ok, %{sprites_destroyed: 0}} = Deletion.delete_user(user) end)
    end

    test "a destroy failure does not abort the deletion" do
      # The reaper reconciles a leftover sprite on its next run. Refusing to
      # delete the account because sprites.dev was briefly unreachable would
      # leave the person unable to leave.
      user = insert_verified_user()
      insert_sandbox(user_id: user.id, status: "ready")
      stub(Sprites, :destroy, fn _ -> {:error, :boom} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.get(User, user.id)
    end

    test "the sandbox row is marked terminated so the reaper can finish the job" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      stub(Sprites, :destroy, fn _ -> {:error, :boom} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert Repo.get(Sandbox, sandbox.id).status == "terminated"
    end
  end

  describe "billing" do
    test "subscriptions are cancelled before anything is destroyed" do
      user = billing_user(%{stripe_customer_id: "cus_123", subscription_status: "active"})

      test = self()

      stub(Stripe.Subscription, :list, fn %{customer: "cus_123"} ->
        {:ok, %{data: [%{id: "sub_1", status: "active"}], has_more: false}}
      end)

      stub(Stripe.Subscription, :cancel, fn "sub_1" ->
        send(test, :cancelled)
        {:ok, %{}}
      end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert_received :cancelled
      refute Repo.get(User, user.id)
    end

    test "a cancellation failure aborts and destroys nothing" do
      # The worst outcome available here is an account that no longer exists but
      # is still being charged — the person has nowhere left to log in and
      # cancel from. So this is the one failure that stops everything.
      user = billing_user(%{stripe_customer_id: "cus_123", subscription_status: "active"})
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      reject(&Sprites.destroy/1)

      stub(Stripe.Subscription, :list, fn _ -> {:error, :stripe_down} end)

      capture_log(fn ->
        assert {:error, {:stripe, :stripe_down}} = Deletion.delete_user(user)
      end)

      assert Repo.get(User, user.id)
      assert Repo.get(Sandbox, sandbox.id).status == "ready"
    end

    test "a trialing subscription is cancelled too" do
      # Filtering the Stripe query to `status: "active"` would be the obvious
      # thing and would miss this: a trial has not charged yet, but it will.
      user = billing_user(%{stripe_customer_id: "cus_123", subscription_status: "trialing"})

      test = self()

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok, %{data: [%{id: "sub_trial", status: "trialing"}], has_more: false}}
      end)

      stub(Stripe.Subscription, :cancel, fn id -> send(test, {:cancelled, id}) && {:ok, %{}} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert_received {:cancelled, "sub_trial"}
    end

    test "an already-cancelled subscription is left alone" do
      user = billing_user(%{stripe_customer_id: "cus_123", subscription_status: "canceled"})

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok, %{data: [%{id: "sub_old", status: "canceled"}], has_more: false}}
      end)

      reject(&Stripe.Subscription.cancel/1)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)
    end

    test "a paged subscription list aborts rather than half-cancelling" do
      # Cancelling page one and reporting success would leave the rest charging
      # an account that no longer exists.
      user = billing_user(%{stripe_customer_id: "cus_123", subscription_status: "active"})

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok, %{data: [%{id: "sub_1", status: "active"}], has_more: true}}
      end)

      capture_log(fn ->
        assert {:error, {:stripe, :too_many_subscriptions}} = Deletion.delete_user(user)
      end)

      assert Repo.get(User, user.id)
    end

    test "a user with no Stripe customer needs no cancellation" do
      user = insert_verified_user()
      reject(&Stripe.Subscription.list/1)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)
    end

    test "Stripe is not consulted when billing is disabled" do
      # A self-hosted instance has no Stripe at all; reaching for it would make
      # deletion fail there.
      user = billing_user(%{stripe_customer_id: "cus_123", subscription_status: "active"})
      reject(&Stripe.Subscription.list/1)

      previous = Application.get_env(:fountain, :billing_enabled)
      Application.put_env(:fountain, :billing_enabled, false)

      try do
        capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)
      after
        Application.put_env(:fountain, :billing_enabled, previous)
      end
    end
  end

  describe "the audit trail" do
    test "records who was deleted, in a form that survives the delete" do
      # audit_events.user_id is SET NULL on delete, so an event relying on the
      # column alone would survive as an anonymous row saying an account was
      # deleted without saying which one.
      user = insert_verified_user()
      email = user.email

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user, actor: "admin:123") end)

      event =
        Repo.one!(
          from e in Fountain.Audit.Event,
            where: e.action == "account.deleted" and e.resource_id == ^user.id
        )

      assert event.user_id == nil
      assert event.actor == "admin:123"
      assert event.metadata["email"] == email
      assert event.metadata["user_id"] == user.id
    end
  end
end
