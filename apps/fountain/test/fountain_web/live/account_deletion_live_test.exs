defmodule FountainWeb.AccountDeletionLiveTest do
  @moduledoc """
  The two surfaces that can close an account: the owner's own account page, and
  an admin acting on a support request.

  These are about the guards rather than the teardown — `Deletion` has its own
  tests for what actually gets removed.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Fountain.Accounts.User
  alias Fountain.Repo

  setup :set_mimic_global

  setup do
    stub(Fountain.Sandbox.Sprites.Client, :get!, fn -> :client end)
    stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)
    stub(Sprites, :destroy, fn _ -> :ok end)
    stub(Fountain.Conversations.ConversationServer, :whereis, fn _ -> nil end)
    :ok
  end

  describe "self-serve, on /account" do
    test "billing disabled: the deletion warning does not mention a subscription", %{conn: conn} do
      # There is no subscription to cancel on a billing-disabled instance —
      # the last billing reference the #513 walkthrough sweep found.
      previous = Application.get_env(:fountain, :billing_enabled)
      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, previous) end)

      user = insert_verified_user()
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account")

      assert html =~ "Destroys every running sandbox"
      refute html =~ "subscription"
    end

    test "billing enabled: the deletion warning covers the subscription", %{conn: conn} do
      previous = Application.get_env(:fountain, :billing_enabled)
      Application.put_env(:fountain, :billing_enabled, true)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, previous) end)

      user = insert_verified_user()
      {:ok, _lv, html} = live(login_user(conn, user), ~p"/account")

      assert html =~ "Cancels your subscription"
    end

    test "typing the account's email deletes it", %{conn: conn} do
      user = insert_verified_user()

      {:ok, lv, html} = live(login_user(conn, user), ~p"/account")
      assert html =~ "Delete account"
      # The export nudge sits in the danger zone and anchors to the export
      # section above it (#450).
      assert html =~ "Request an export above"
      assert html =~ ~s{id="export"}

      capture_log(fn ->
        assert {:error, {:redirect, %{to: to}}} =
                 render_submit(lv, "delete_account", %{"email" => user.email})

        # Out through the controller, because a LiveView cannot drop the
        # session cookie itself — leaving a signed-in session for a user row
        # that no longer exists.
        assert to =~ "/auth/logout"
        assert to =~ "deleted=1"
      end)

      refute Repo.get(User, user.id)
    end

    test "the wrong email deletes nothing", %{conn: conn} do
      user = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      html = render_submit(lv, "delete_account", %{"email" => "someone-else@example.com"})

      assert html =~ "Type your email address exactly to confirm"
      assert Repo.get(User, user.id)
    end

    test "an empty confirmation deletes nothing", %{conn: conn} do
      user = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")
      render_submit(lv, "delete_account", %{"email" => ""})

      assert Repo.get(User, user.id)
    end

    test "a Stripe failure reports it and keeps the account", %{conn: conn} do
      user = insert_verified_user()

      {:ok, user} =
        user
        |> User.billing_changeset(%{stripe_customer_id: "cus_x", subscription_status: "active"})
        |> Repo.update()

      stub(Stripe.Subscription, :list, fn _ -> {:error, :down} end)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      html =
        with_log(fn -> render_submit(lv, "delete_account", %{"email" => user.email}) end)
        |> elem(0)

      assert html =~ "subscription could not be cancelled"
      assert html =~ "nothing was deleted"
      assert Repo.get(User, user.id)
    end
  end

  describe "admin" do
    test "an admin can delete another account", %{conn: conn} do
      admin = insert_verified_user(role: "admin")
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")

      capture_log(fn ->
        html = render_click(lv, "delete_user", %{"id" => target.id})
        assert html =~ "Deleted #{target.email}"
      end)

      refute Repo.get(User, target.id)
      assert Repo.get(User, admin.id)
    end

    test "an admin cannot delete themselves from the admin page", %{conn: conn} do
      # The button is hidden for their own row, but the event can still be sent
      # by hand — and an admin deleting themselves mid-session is a support
      # problem rather than a feature.
      admin = insert_verified_user(role: "admin")

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")

      html = render_click(lv, "delete_user", %{"id" => admin.id})

      assert html =~ "Use your own account page"
      assert Repo.get(User, admin.id)
    end

    test "the deletion is recorded against the admin who did it" do
      admin = insert_verified_user(role: "admin")
      target = insert_verified_user()

      capture_log(fn ->
        assert {:ok, _} =
                 Fountain.Accounts.Deletion.delete_user(target, actor: "admin:#{admin.id}")
      end)

      event =
        Repo.one!(
          from e in Fountain.Audit.Event,
            where: e.action == "account.deleted" and e.resource_id == ^target.id
        )

      assert event.actor == "admin:#{admin.id}"
    end

    test "a non-admin cannot reach the admin page at all", %{conn: conn} do
      user = insert_verified_user()

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(login_user(conn, user), ~p"/admin")
    end
  end
end
