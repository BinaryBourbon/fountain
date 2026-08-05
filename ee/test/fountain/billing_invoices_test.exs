# async: false — the billing-disabled case mutates the global :billing_enabled
# app env, which concurrent tests also read.
defmodule Fountain.BillingInvoicesTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.Billing

  setup do
    billing = Application.get_env(:fountain, :billing_enabled)
    on_exit(fn -> Application.put_env(:fountain, :billing_enabled, billing) end)
    :ok
  end

  defp user_with_customer(customer_id) do
    {:ok, user} =
      insert_verified_user()
      |> User.billing_changeset(%{stripe_customer_id: customer_id})
      |> Repo.update()

    user
  end

  # stripity_stripe's functions carry a default opts arg, and Mimic stubs
  # are arity-specific — stub both arities or the miss silently falls
  # through to the live client (#474).
  defp stub_list(result) do
    stub(Stripe.Invoice, :list, fn _params -> result end)
    stub(Stripe.Invoice, :list, fn _params, _opts -> result end)
  end

  describe "list_invoices/1 (#502)" do
    test "fetches the customer's invoices live from Stripe" do
      user = user_with_customer("cus_inv")

      invoice = %Stripe.Invoice{id: "in_1", number: "INV-0001", status: "paid", total: 2900}

      stub(Stripe.Invoice, :list, fn %{customer: "cus_inv", limit: 20} ->
        {:ok, %Stripe.List{data: [invoice]}}
      end)

      stub(Stripe.Invoice, :list, fn %{customer: "cus_inv", limit: 20}, _opts ->
        {:ok, %Stripe.List{data: [invoice]}}
      end)

      assert {:ok, [%Stripe.Invoice{id: "in_1"}]} = Billing.list_invoices(user)
    end

    test "a user with no Stripe customer has no invoices, without a Stripe call" do
      stub_list_flunk()
      assert {:ok, []} = Billing.list_invoices(insert_verified_user())
    end

    test "refused before Stripe when billing is disabled" do
      Application.put_env(:fountain, :billing_enabled, false)
      stub_list_flunk()
      assert {:error, :billing_disabled} = Billing.list_invoices(user_with_customer("cus_inv"))
    end

    test "a Stripe error passes through" do
      user = user_with_customer("cus_down")
      stub_list({:error, :stripe_down})
      assert {:error, :stripe_down} = Billing.list_invoices(user)
    end
  end

  # For cases asserting Stripe is never reached: the stub runs in the test
  # process, so flunk surfaces as a normal test failure.
  defp stub_list_flunk do
    stub(Stripe.Invoice, :list, fn _params -> flunk("Stripe.Invoice.list was called") end)

    stub(Stripe.Invoice, :list, fn _params, _opts ->
      flunk("Stripe.Invoice.list was called")
    end)
  end
end
