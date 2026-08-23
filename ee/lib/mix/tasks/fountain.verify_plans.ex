defmodule Mix.Tasks.Fountain.VerifyPlans do
  @shortdoc "Check the plan catalog against the prices configured in Stripe"

  @moduledoc """
  Verify that every plan Fountain advertises matches what Stripe will charge.

      STRIPE_SECRET_KEY=sk_... \\
        STRIPE_PRICE_ID_SOLO=price_... \\
        STRIPE_PRICE_ID_TEAM=price_... \\
        STRIPE_PRICE_ID_SCALE=price_... \\
        mix fountain.verify_plans

  ## What it catches

  `Fountain.Plans` carries a display price per tier; Stripe carries the price
  that is actually charged. Nothing links the two — the catalog is code and
  the price id is an env var — so a price changed in the Stripe dashboard, or
  an env var pointed at the wrong tier's price, shows the customer one number
  and bills them another. That is the failure this task exists to catch, and
  it is invisible until an invoice lands.

  For each plan with a price id configured it checks that the price:

    * exists and is active;
    * is a recurring monthly price (a one-off price would charge once and
      leave the subscription with nothing to renew);
    * is in USD, the currency every catalog figure is written in;
    * charges exactly `monthly_cents`.

  The teammate-contact add-on is checked the same way, with the extra
  requirement that it is a *licensed* price — the quantity is set from the
  contact count, and a metered price ignores a quantity entirely.

  A plan with no price id is reported as unconfigured, not as a failure: a
  deployment rolls its price ids out one at a time, and only the plans that
  have one are sellable (`Billing.available_plans/0`).

  ## When to run it

  Before announcing a price, after changing one, and after any deployment
  that sets a `STRIPE_PRICE_ID_*` variable. It is read-only — it creates
  nothing in Stripe and touches no database — so it is safe against live
  mode, which is where it is worth running.

  Exits non-zero if any configured price fails a check, so it can gate a
  release step.
  """

  use Mix.Task

  alias Fountain.Plans

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:hackney)
    {:ok, _} = Application.ensure_all_started(:stripity_stripe)

    unless configured_key?() do
      abort("STRIPE_SECRET_KEY is not set — there is nothing to verify against.")
    end

    results = Enum.map(Plans.all(), &check_plan/1) ++ [check_contact_addon()]

    Enum.each(results, &report/1)

    failures = Enum.count(results, &match?({:fail, _, _}, &1))

    IO.puts("")

    if failures == 0 do
      IO.puts("All configured prices match the catalog.")
    else
      abort("#{failures} price(s) do not match the catalog — see above.")
    end
  end

  # `IO.puts` rather than `Mix.shell()`, and a plain raise rather than
  # `Mix.raise`: `Mix` is not in a prod release, so every `Mix.*` call at
  # runtime blew up the moment this ran the way the operator guide says to run
  # it — `bin/fountain_server rpc`. It got as far as talking to Stripe and then
  # died printing the answer (#1018).
  #
  # `use Mix.Task` above is fine: that is compile-time, so the module is in the
  # release and `rpc` can reach it.
  defp abort(message) do
    IO.warn(message, [])
    raise message
  end

  defp check_plan(plan) do
    case Plans.price_id(plan) do
      nil ->
        {:skip, label(plan), "no price id configured — this plan cannot be subscribed to"}

      price_id ->
        verify_price(label(plan), price_id, plan.monthly_cents, licensed?: false)
    end
  end

  defp check_contact_addon do
    case Plans.contact_price_id() do
      nil ->
        {:skip, "teammate contact add-on",
         "no price id configured — teammate contacts are not billed"}

      price_id ->
        verify_price("teammate contact add-on", price_id, Plans.contact_monthly_cents(),
          licensed?: true
        )
    end
  end

  defp verify_price(label, price_id, expected_cents, opts) do
    case Stripe.Price.retrieve(price_id) do
      {:ok, price} ->
        case problems(price, expected_cents, opts) do
          [] -> {:ok, label, "#{price_id} — #{Plans.format_usd(expected_cents)}/mo"}
          problems -> {:fail, label, "#{price_id}: " <> Enum.join(problems, "; ")}
        end

      {:error, reason} ->
        {:fail, label, "#{price_id}: could not be retrieved (#{describe(reason)})"}
    end
  end

  defp problems(price, expected_cents, opts) do
    recurring = Map.get(price, :recurring)

    [
      unless_ok(Map.get(price, :active) == true, "the price is archived in Stripe"),
      unless_ok(
        Map.get(price, :unit_amount) == expected_cents,
        "Stripe charges #{format_amount(Map.get(price, :unit_amount))}, " <>
          "the catalog says #{Plans.format_usd(expected_cents)}"
      ),
      unless_ok(
        String.downcase(to_string(Map.get(price, :currency) || "")) == "usd",
        "currency is #{Map.get(price, :currency)}, the catalog is written in USD"
      ),
      unless_ok(is_map(recurring), "not a recurring price — a subscription cannot renew on it"),
      unless_ok(
        !is_map(recurring) or to_string(Map.get(recurring, :interval)) == "month",
        "renews every #{recurring && Map.get(recurring, :interval)}, not monthly"
      ),
      unless_ok(
        !opts[:licensed?] or !is_map(recurring) or
          to_string(Map.get(recurring, :usage_type)) in ["licensed", ""],
        "is a metered price — a quantity set from the contact count would be ignored"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp unless_ok(true, _message), do: nil
  defp unless_ok(_false, message), do: message

  defp report({:ok, label, detail}), do: IO.puts("  ok    #{label}: #{detail}")
  defp report({:skip, label, detail}), do: IO.puts("  --    #{label}: #{detail}")
  defp report({:fail, label, detail}), do: IO.puts(:stderr, "  FAIL  #{label}: #{detail}")

  defp label(plan) do
    if plan.public?, do: plan.name, else: "#{plan.name} (closed)"
  end

  defp format_amount(nil), do: "nothing"
  defp format_amount(cents) when is_integer(cents), do: Plans.format_usd(cents)
  defp format_amount(other), do: inspect(other)

  # Stripe hands back a %Stripe.Error{}, whose :message is always a binary.
  defp describe(%{message: message}), do: message

  defp configured_key? do
    key = Application.get_env(:stripity_stripe, :api_key)
    is_binary(key) and key != ""
  end
end
