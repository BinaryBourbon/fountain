defmodule FountainWeb.AdminUserDetailLiveTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Fountain.Accounts
  alias Fountain.Audit.AdminEvent
  alias Fountain.Repo

  defp insert_admin(overrides \\ %{}) do
    user = insert_verified_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "access control" do
    test "regular user is redirected away", %{conn: conn} do
      user = insert_verified_user()
      target = insert_verified_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin/users/#{target.id}")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      target = insert_verified_user()
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/users/#{target.id}")
      assert path =~ "/auth/login"
    end
  end

  describe "detail page" do
    test "shows another tenant's account, conversations and API-key metadata", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()
      conv = insert_conversation(user_id: target.id)
      {_key, _raw} = insert_api_key(target, "support-visible-key")

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{target.id}")

      assert html =~ target.email
      assert html =~ String.slice(conv.id, 0, 8)
      assert html =~ "support-visible-key"
      # key material never renders — only the prefix column
      refute html =~ "key_hash"
    end

    test "shows admin actions taken against the account", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()

      {:ok, _} =
        Fountain.Audit.record_admin(%{
          actor_user_id: admin.id,
          target_user_id: target.id,
          event_type: "admin.account.suspended",
          metadata: %{"email" => target.email}
        })

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{target.id}")

      assert html =~ "admin.account.suspended"
    end

    test "records an admin.user.viewed audit event on visit", %{conn: conn} do
      admin = insert_admin()
      target = insert_verified_user()

      conn = login_user(conn, admin)
      {:ok, _lv, _html} = live(conn, ~p"/admin/users/#{target.id}")

      assert [event] =
               Repo.all(
                 from e in AdminEvent,
                   where: e.event_type == "admin.user.viewed" and e.target_user_id == ^target.id
               )

      assert event.actor_user_id == admin.id
      assert event.metadata["email"] == target.email
    end

    test "unknown user id redirects back to /admin with a flash", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               live(conn, ~p"/admin/users/#{Ecto.UUID.generate()}")
    end
  end

  describe "invoices (#502)" do
    defp insert_target_with_customer(customer_id) do
      {:ok, user} =
        insert_verified_user()
        |> Accounts.User.billing_changeset(%{stripe_customer_id: customer_id})
        |> Repo.update()

      user
    end

    # Both arities, or the miss silently falls through to the live client
    # (#474): stripity_stripe functions carry a default opts arg.
    defp stub_invoice_list(result) do
      stub(Stripe.Invoice, :list, fn _params -> result end)
      stub(Stripe.Invoice, :list, fn _params, _opts -> result end)
    end

    test "renders the invoice history fetched from Stripe", %{conn: conn} do
      target = insert_target_with_customer("cus_inv_lv")

      stub_invoice_list(
        {:ok,
         %Stripe.List{
           data: [
             %Stripe.Invoice{
               id: "in_lv_1",
               number: "INV-2026-0001",
               status: "paid",
               total: 2900,
               currency: "usd",
               created: 1_754_000_000
             }
           ]
         }}
      )

      {:ok, lv, _html} = live(login_user(conn, insert_admin()), ~p"/admin/users/#{target.id}")

      invoices = lv |> element("#invoices") |> render()
      assert invoices =~ "INV-2026-0001"
      assert invoices =~ "paid"
      assert invoices =~ "$29.00"
      assert invoices =~ "https://dashboard.stripe.com/invoices/in_lv_1"
    end

    test "a Stripe failure degrades to an error note, not a broken page", %{conn: conn} do
      target = insert_target_with_customer("cus_inv_down")
      stub_invoice_list({:error, :stripe_down})

      {:ok, lv, _html} = live(login_user(conn, insert_admin()), ~p"/admin/users/#{target.id}")

      invoices = lv |> element("#invoices") |> render()
      assert invoices =~ "Couldn&#39;t load invoices from Stripe"
      assert invoices =~ "https://dashboard.stripe.com/customers/cus_inv_down"
    end

    test "a user with no Stripe customer shows an empty state", %{conn: conn} do
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, insert_admin()), ~p"/admin/users/#{target.id}")

      assert lv |> element("#invoices") |> render() =~ "None."
    end
  end
end
