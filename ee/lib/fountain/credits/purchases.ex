defmodule Fountain.Credits.Purchases do
  @moduledoc """
  Buying credits, and taking them back when the money goes back (ADR 0030
  decision 5): Fountain owns the ledger, Stripe is the till.

    * `checkout_url/3` opens a one-time Stripe Checkout in `mode: :payment`
      for one of `Credits.packs/0`. Only a subscriber may buy — a trialing
      account is refused (`{:error, :subscription_required}`), because
      buying is a spend and the gate for spend is "subscribe first" (ADR
      0006); a comped account is refused (`{:error, :comped}`) because it
      has nothing to pay for.
    * `complete/1` grants the pack when `checkout.session.completed` arrives
      for a payment-mode session Fountain opened, under `purchase:<session>`.
      The payment intent id is kept on the row so a refund can find it.
    * `refund/1` claws back on `charge.refunded`. Refunds are cumulative and
      can be partial, so the debit is the charge's `amount_refunded` less
      what this charge has already been clawed back, under
      `clawback_refund:<charge>:<amount_refunded>`.
    * `dispute/1` claws back the disputed amount on `charge.dispute.created`
      under `clawback_dispute:<dispute>`. A dispute later won is not credited
      back automatically — that is an operator's `grant_admin`, on purpose,
      because a won dispute is rare and a wrong automatic re-grant is free
      money.

  A clawback may take the balance below zero. That is the point: a refunded
  pack that was already spent is a debt, and hiding it would be the
  free-money bug the ADR names.

  The Stripe endpoint must be subscribed to `charge.refunded` and
  `charge.dispute.created` for the clawbacks to arrive; the operator docs say
  so.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  require Logger

  @metadata_marker "fountain_credits_cents"

  @doc """
  A Stripe Checkout URL for `cents` of credit. `cents` must be one of
  `Credits.packs/0`.
  """
  @spec checkout_url(User.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def checkout_url(%User{subscription_status: "comped"}, _cents, _return_url),
    do: {:error, :comped}

  def checkout_url(%User{subscription_status: status}, _cents, _return_url)
      when status not in ~w(active past_due),
      do: {:error, :subscription_required}

  def checkout_url(%User{} = user, cents, return_url) when is_integer(cents) do
    if cents in Credits.packs() do
      with {:ok, user} <- Billing.ensure_stripe_customer(user) do
        metadata = %{@metadata_marker => Integer.to_string(cents), "fountain_user_id" => user.id}

        params = %{
          mode: :payment,
          line_items: [
            %{
              price_data: %{
                currency: "usd",
                unit_amount: cents,
                product_data: %{name: "Fountain credits, #{Credits.format_cents(cents)}"}
              },
              quantity: 1
            }
          ],
          success_url: return_url <> "?credits=success",
          cancel_url: return_url,
          customer: user.stripe_customer_id,
          client_reference_id: user.id,
          metadata: metadata,
          # Copied onto the PaymentIntent so the charge a refund names can be
          # traced back even if the session is gone.
          payment_intent_data: %{metadata: metadata}
        }

        case Stripe.Checkout.Session.create(params) do
          {:ok, session} -> {:ok, session.url}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :unknown_pack}
    end
  end

  @doc "Whether a Checkout session is one of ours in payment mode."
  @spec credits_session?(map()) :: boolean()
  def credits_session?(session) do
    Map.get(session, :mode) in ["payment", :payment] and is_map(Map.get(session, :metadata)) and
      Map.has_key?(Map.get(session, :metadata), @metadata_marker)
  end

  @doc """
  Grant the pack a completed payment-mode session paid for. Returns
  `{:ok, entry}`, `{:ok, :duplicate, entry}`, or an error when the session
  is not ours or names no user.
  """
  @spec complete(map()) :: Credits.post_result() | {:error, :not_credits | :user_not_found}
  def complete(session) do
    with true <- credits_session?(session) || {:error, :not_credits},
         {:ok, cents} <- pack_cents(session),
         %User{} = user <- session_user(session) || {:error, :user_not_found} do
      Credits.grant(user.id, cents, "purchase",
        idempotency_key: "purchase:#{Map.get(session, :id)}",
        resource_type: "stripe_checkout_session",
        resource_id: Map.get(session, :id),
        actor: "system:stripe_webhook",
        metadata: %{
          "payment_intent" => stripe_id(Map.get(session, :payment_intent)),
          "amount_total" => Map.get(session, :amount_total)
        }
      )
    end
  end

  defp pack_cents(session) do
    case Integer.parse(Map.get(session.metadata, @metadata_marker, "")) do
      {cents, ""} when cents > 0 -> {:ok, cents}
      _ -> {:error, :not_credits}
    end
  end

  defp session_user(session) do
    customer_id = stripe_id(Map.get(session, :customer))

    user_id =
      Map.get(session, :client_reference_id) || get_in(session, [:metadata, "fountain_user_id"])

    (is_binary(customer_id) && Repo.get_by(User, stripe_customer_id: customer_id)) ||
      (is_binary(user_id) && Repo.get(User, user_id)) || nil
  end

  @doc """
  Claw back what a refunded charge has returned to the customer, less what
  was already clawed back for that charge. `{:ok, :nothing}` when the charge
  is not a credits purchase or nothing new was refunded.
  """
  @spec refund(map()) :: Credits.post_result() | {:ok, :nothing}
  def refund(charge) do
    charge_id = Map.get(charge, :id)
    refunded = Map.get(charge, :amount_refunded) || 0

    case purchase_for(stripe_id(Map.get(charge, :payment_intent))) do
      nil ->
        {:ok, :nothing}

      %LedgerEntry{} = purchase ->
        already = clawed_back(purchase.user_id, "clawback_refund", charge_id)
        delta = refunded - already

        if delta > 0 do
          Credits.debit(purchase.user_id, delta, "clawback_refund",
            idempotency_key: "clawback_refund:#{charge_id}:#{refunded}",
            lot_id: purchase.id,
            resource_type: "stripe_charge",
            resource_id: charge_id,
            actor: "system:stripe_webhook",
            metadata: %{"purchase_id" => purchase.id, "amount_refunded" => refunded}
          )
        else
          {:ok, :nothing}
        end
    end
  end

  @doc "Claw back a disputed amount. `{:ok, :nothing}` when the charge is not a credits purchase."
  @spec dispute(map()) :: Credits.post_result() | {:ok, :nothing}
  def dispute(dispute) do
    amount = Map.get(dispute, :amount) || 0

    case purchase_for(stripe_id(Map.get(dispute, :payment_intent))) do
      %LedgerEntry{} = purchase when amount > 0 ->
        Credits.debit(purchase.user_id, amount, "clawback_dispute",
          idempotency_key: "clawback_dispute:#{Map.get(dispute, :id)}",
          lot_id: purchase.id,
          resource_type: "stripe_dispute",
          resource_id: Map.get(dispute, :id),
          actor: "system:stripe_webhook",
          metadata: %{
            "purchase_id" => purchase.id,
            "charge" => stripe_id(Map.get(dispute, :charge)),
            "reason" => Map.get(dispute, :reason)
          }
        )

      _ ->
        {:ok, :nothing}
    end
  end

  defp purchase_for(nil), do: nil

  defp purchase_for(payment_intent) when is_binary(payment_intent) do
    from(e in LedgerEntry,
      where: e.reason == "purchase",
      where: fragment("? ->> 'payment_intent' = ?", e.metadata, ^payment_intent),
      limit: 1
    )
    |> Repo.one()
  end

  defp clawed_back(user_id, reason, resource_id) do
    from(e in LedgerEntry,
      where: e.user_id == ^user_id and e.reason == ^reason and e.resource_id == ^resource_id,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.one()
    |> Kernel.-()
  end

  defp stripe_id(value) when is_binary(value), do: value
  defp stripe_id(%{id: id}) when is_binary(id), do: id
  defp stripe_id(_), do: nil
end
