defmodule Fountain.Credits do
  @moduledoc """
  The prepaid credit ledger (ADR 0030).

  A tenant's balance is a number of **cents**, cached on
  `users.credit_balance_cents` and backed by the append-only `credit_ledger`.
  Money comes in as a grant (the tier's monthly allowance, the trial's opening
  grant, an operator's comp) or a purchase, and goes out as a burn (turn
  hours, rent, messages), an expiry, or a clawback after a refund or dispute.

  Three properties every writer relies on:

    * **Idempotent.** Every row carries a unique `idempotency_key`. Posting the
      same key twice returns the original row and writes nothing, so a worker
      can re-price a turn, a webhook can arrive twice, and a sweep can restart
      without touching the balance.
    * **The cache is the balance.** The row and the `UPDATE users SET
      credit_balance_cents = credit_balance_cents + amount` land in one
      transaction; a gate reads the column and never sums the ledger.
      `recompute_balance/1` exists for reconciliation, not for reads.
    * **Short-circuit before the ledger.** `check_balance/1` answers `:ok` for
      a deployment with billing off and for a comped tenant *before* reading
      the balance, so a self-hosted install and a comp never brick at zero
      (the `turn_hour_allowance/2` trialing-defaults failure class, ADR 0030
      decision 7).

  ## What is built

  This module: post, grant, debit, balance, check_balance, list, recompute,
  and the price card. **Nothing calls `check_balance/1` to refuse anything
  yet** — that is #1086 phase 4 — and nothing writes burn rows until the
  pricing workers land (phase 2, steps 2 and 3). The ledger exists so that
  they have somewhere to write.

  ## Audit

  Every posted row leaves one `credit.*` event: `credit.granted`,
  `credit.purchased`, `credit.burned`, `credit.expired`, `credit.clawed_back`.
  Metadata carries the amount, reason and resource reference — cents are not
  tenant data — never a balance, which is derivable and would go stale.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.Billing
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  require Logger

  @type post_result ::
          {:ok, LedgerEntry.t()} | {:ok, :duplicate, LedgerEntry.t()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Prices
  # ---------------------------------------------------------------------------

  @doc """
  The customer price card, in cents. `:turn_hour` is what one hour of
  `turn_seconds` burns (ADR 0030 decision 3; the number is a placeholder until
  #1038 produces a provider cost). The four comms prices are `nil` until an
  operator sets them, and a `nil` price burns nothing — turning one on is a
  price increase and an explicit act (#1042).

  Read from `config :fountain, :credits`; runtime.exs fills it from
  `CREDIT_TURN_HOUR_CENTS`, `CREDIT_NUMBER_CENTS`, `CREDIT_INBOX_CENTS`,
  `CREDIT_EMAIL_MESSAGE_CENTS` and `CREDIT_SMS_MESSAGE_CENTS`.
  """
  @spec price_card() :: %{
          turn_hour: non_neg_integer(),
          number_month: non_neg_integer() | nil,
          inbox_month: non_neg_integer() | nil,
          email_message: non_neg_integer() | nil,
          sms_message: non_neg_integer() | nil
        }
  def price_card do
    cfg = Application.get_env(:fountain, :credits, [])

    %{
      turn_hour: Keyword.get(cfg, :turn_hour_cents, 25),
      number_month: Keyword.get(cfg, :number_cents),
      inbox_month: Keyword.get(cfg, :inbox_cents),
      email_message: Keyword.get(cfg, :email_message_cents),
      sms_message: Keyword.get(cfg, :sms_message_cents)
    }
  end

  @doc """
  The credit packs a tenant can buy, in cents, ascending. Default
  $10 / $25 / $100 (`CREDIT_PACKS_CENTS="1000,2500,10000"`).
  """
  @spec packs() :: [pos_integer()]
  def packs do
    Application.get_env(:fountain, :credits, [])
    |> Keyword.get(:packs_cents, [1_000, 2_500, 10_000])
  end

  @doc """
  Cents that `turn_seconds` of conversation time burns, rounded to the
  nearest cent. Integer arithmetic on purpose: a ledger of fractional cents
  is a ledger nobody can reconcile.
  """
  @spec turn_cost_cents(non_neg_integer()) :: non_neg_integer()
  def turn_cost_cents(turn_seconds) when is_integer(turn_seconds) and turn_seconds >= 0 do
    div(turn_seconds * price_card().turn_hour + 1_800, 3_600)
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  The tenant's balance in cents, from the cache. Negative is possible: an
  in-flight turn that crosses zero finishes and lands as debt (ADR 0030
  decision 6), and a clawback after a refund can take a spent balance below
  zero.
  """
  @spec balance(User.t() | binary()) :: integer()
  def balance(%User{credit_balance_cents: cents}) when is_integer(cents), do: cents

  def balance(user_id) when is_binary(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.credit_balance_cents)
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Whether the tenant may spend. `:ok` when billing is off or the account is
  comped, before any balance read; `:ok` when the cached balance is positive;
  `{:error, :insufficient_credits}` otherwise.

  Nothing calls this to refuse anything yet (#1086 phase 4).
  """
  @spec check_balance(User.t() | binary()) :: :ok | {:error, :insufficient_credits}
  def check_balance(subject) do
    cond do
      not Billing.enabled?() -> :ok
      comped?(subject) -> :ok
      balance(subject) > 0 -> :ok
      true -> {:error, :insufficient_credits}
    end
  end

  defp comped?(%User{subscription_status: status}), do: status == "comped"

  defp comped?(user_id) when is_binary(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.subscription_status)
    |> Repo.one() == "comped"
  end

  @doc "The ledger for one tenant, newest first. `:limit` defaults to 100."
  @spec list_entries(binary(), keyword()) :: [LedgerEntry.t()]
  def list_entries(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 100)

    from(e in LedgerEntry,
      where: e.user_id == ^user_id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "One entry by idempotency key, or nil."
  @spec get_by_key(String.t()) :: LedgerEntry.t() | nil
  def get_by_key(key) when is_binary(key), do: Repo.get_by(LedgerEntry, idempotency_key: key)

  @doc """
  Sum the ledger for one tenant and write it to the cache. For reconciliation
  (a release task, a test); never on a request path. Returns the recomputed
  balance.
  """
  @spec recompute_balance(binary()) :: integer()
  def recompute_balance(user_id) when is_binary(user_id) do
    total =
      from(e in LedgerEntry,
        where: e.user_id == ^user_id,
        select: coalesce(sum(e.amount_cents), 0)
      )
      |> Repo.one()

    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [credit_balance_cents: total])

    total
  end

  @doc """
  Tenants whose cached balance disagrees with their ledger — `[{user_id,
  cached, actual}]`. Empty is the invariant.
  """
  @spec drift() :: [{binary(), integer(), integer()}]
  def drift do
    from(u in User,
      left_join: e in LedgerEntry,
      on: e.user_id == u.id,
      group_by: u.id,
      having: u.credit_balance_cents != coalesce(sum(e.amount_cents), 0),
      select: {u.id, u.credit_balance_cents, coalesce(sum(e.amount_cents), 0)}
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  @doc """
  Put money in. `reason` is one of `LedgerEntry.credit_reasons/0`; `cents` is
  positive.

  Options: `:idempotency_key` (required), `:expires_at` (a grant that stops
  being spendable), `:resource_type` / `:resource_id`, `:metadata`, and the
  usual audit attribution (`:actor`, `:request_ip`).
  """
  @spec grant(binary(), pos_integer(), String.t(), keyword()) :: post_result()
  def grant(user_id, cents, reason, opts) when is_integer(cents) and cents > 0 do
    post(user_id, cents, reason, opts)
  end

  @doc """
  Take money out. `reason` is one of `LedgerEntry.debit_reasons/0`; `cents` is
  positive and is stored negated. A debit may drive the balance below zero;
  refusing to spend is the gate's job, not the ledger's.
  """
  @spec debit(binary(), pos_integer(), String.t(), keyword()) :: post_result()
  def debit(user_id, cents, reason, opts) when is_integer(cents) and cents > 0 do
    post(user_id, -cents, reason, opts)
  end

  @doc """
  Post one signed row and move the cached balance by the same amount, in one
  transaction. Returns `{:ok, entry}`, `{:ok, :duplicate, entry}` when the
  idempotency key was already posted (nothing written), or an error.

  Prefer `grant/4` and `debit/4`, which fix the sign.
  """
  @spec post(binary(), integer(), String.t(), keyword()) :: post_result()
  def post(user_id, amount_cents, reason, opts)
      when is_binary(user_id) and is_integer(amount_cents) do
    key = Keyword.fetch!(opts, :idempotency_key)

    attrs = %{
      user_id: user_id,
      amount_cents: amount_cents,
      reason: reason,
      idempotency_key: key,
      resource_type: Keyword.get(opts, :resource_type),
      resource_id: Keyword.get(opts, :resource_id),
      expires_at: Keyword.get(opts, :expires_at),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    changeset = LedgerEntry.changeset(%LedgerEntry{}, attrs)

    if changeset.valid? do
      changeset |> insert_and_move() |> audited(opts)
    else
      {:error, changeset}
    end
  end

  # The unique index is the idempotency guard, and the duplicate is detected
  # *after* attempting the insert rather than by a lookup first: two workers
  # posting the same key at once must not both see "absent" and both move the
  # balance. A duplicate aborts the transaction, so the balance is untouched.
  defp insert_and_move(changeset) do
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)
    user_id = Ecto.Changeset.get_field(changeset, :user_id)
    amount = Ecto.Changeset.get_field(changeset, :amount_cents)

    Repo.transaction(fn ->
      with {:ok, entry} <- Repo.insert(changeset),
           {1, _} <-
             Repo.update_all(from(u in User, where: u.id == ^user_id),
               inc: [credit_balance_cents: amount]
             ) do
        entry
      else
        # Cannot happen while the FK holds, but a ledger row without a user
        # row to carry its balance would be a silent drift.
        {0, _} -> Repo.rollback(:user_not_found)
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
      end
    end)
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :idempotency_key) do
          case get_by_key(key) do
            nil -> {:error, cs}
            existing -> {:ok, :duplicate, existing}
          end
        else
          {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Recorded outside the transaction (ADR 0013): a best-effort audit write
  # inside it would take the ledger row down with it.
  defp audited({:ok, %LedgerEntry{} = entry} = ok, opts) do
    Audit.record(%{
      user_id: entry.user_id,
      action: audit_action(entry.reason),
      resource_type: "credit_ledger",
      resource_id: entry.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata:
        %{
          "amount_cents" => entry.amount_cents,
          "reason" => entry.reason,
          "target_type" => entry.resource_type,
          "target_id" => entry.resource_id
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)
    })

    ok
  end

  defp audited(other, _opts), do: other

  defp audit_action("purchase"), do: "credit.purchased"
  defp audit_action("grant_" <> _), do: "credit.granted"
  defp audit_action("burn_" <> _), do: "credit.burned"
  defp audit_action("expire"), do: "credit.expired"
  defp audit_action("clawback_" <> _), do: "credit.clawed_back"

  @doc ~S|Cents as a dollar string for display: `1240` → `"$12.40"`, `-5` → `"-$0.05"`.|
  @spec format_cents(integer()) :: String.t()
  def format_cents(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs = abs(cents)
    dollars = div(abs, 100)
    rem = rem(abs, 100)
    "#{sign}$#{dollars}.#{String.pad_leading(Integer.to_string(rem), 2, "0")}"
  end
end
