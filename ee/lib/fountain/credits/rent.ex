defmodule Fountain.Credits.Rent do
  @moduledoc """
  Rent for a teammate's number and inbox (ADR 0030 decision 4): a month up
  front at provisioning, and again on each monthly anniversary.

    * `month_cents/0` is `CREDIT_NUMBER_CENTS + CREDIT_INBOX_CENTS`; unset
      prices are zero, and zero rent means nothing here does anything.
    * `check_provision/1` refuses a new contact when enforcement is on and
      the balance is short of one month (`{:error, :insufficient_credits}`).
    * `charge/3` debits one month for a contact under
      `burn_rent:<contact>:<period_start>` and moves `rent_paid_through` one
      month on. With enforcement off the debit always lands, negative or not.
      With it on, a short balance leaves the row unpaid and stamps
      `rent_due_at`, which starts the grace.
    * `collect/1` is the daily pass: charge every contact whose month is up,
      email the tenant at day 0, 3 and 6 of the grace, and release the
      contact on day 7 through `Team.Comms.release_contact/3`. Release is
      irreversible — the number is gone — which is why it is the only spend
      that waits (decision 6).
  """

  import Ecto.Query

  alias Fountain.Credits
  alias Fountain.Repo
  alias Fountain.Team.Comms
  alias Fountain.Team.Contact

  require Logger

  @grace_days 7
  @reminder_days [0, 3, 6]

  @doc "One month of rent for a contact that holds a number and an inbox, in cents."
  @spec month_cents() :: non_neg_integer()
  def month_cents do
    card = Credits.price_card()
    (card.number_month || 0) + (card.inbox_month || 0)
  end

  @doc "Whether rent is charged at all: credits active and a price set."
  @spec charging?() :: boolean()
  def charging?, do: Credits.active?() and month_cents() > 0

  @doc """
  Whether a tenant may provision a contact. Only refuses under enforcement,
  and only when the balance cannot cover the first month.
  """
  @spec check_provision(binary()) :: :ok | {:error, :insufficient_credits}
  def check_provision(user_id) when is_binary(user_id) do
    if Credits.enforcing?() and month_cents() > 0 and Credits.balance(user_id) < month_cents(),
      do: {:error, :insufficient_credits},
      else: :ok
  end

  @doc """
  Debit one month starting at `period_start` for `contact`. Returns
  `{:ok, contact}` with `rent_paid_through` advanced, `{:ok, :duplicate,
  contact}` when that month was already charged, `{:error,
  :insufficient_credits}` when enforcement refused it (and `rent_due_at` is
  now set), or `{:ok, :free}` when nothing is charged on this deployment.
  """
  @spec charge(Contact.t(), DateTime.t(), keyword()) ::
          {:ok, Contact.t()} | {:ok, :duplicate, Contact.t()} | {:ok, :free} | {:error, term()}
  def charge(%Contact{} = contact, %DateTime{} = period_start, opts \\ []) do
    cents = month_cents()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    cond do
      not charging?() ->
        {:ok, :free}

      Credits.enforcing?() and Credits.balance(contact.user_id) < cents ->
        {:ok, _} = stamp(contact, rent_due_at: contact.rent_due_at || truncate(now))
        {:error, :insufficient_credits}

      true ->
        key = "burn_rent:#{contact.id}:#{DateTime.to_iso8601(period_start)}"

        case Credits.debit(contact.user_id, cents, "burn_rent",
               idempotency_key: key,
               resource_type: "team_contact",
               resource_id: contact.id,
               actor: Keyword.get(opts, :actor, "system:credit_rent"),
               metadata: %{
                 "period_start" => DateTime.to_iso8601(period_start),
                 "agent_id" => contact.agent_id
               }
             ) do
          {:ok, _} ->
            stamp(contact, rent_paid_through: add_month(period_start), rent_due_at: nil)

          {:ok, :duplicate, _} ->
            {:ok, contact} =
              stamp(contact, rent_paid_through: add_month(period_start), rent_due_at: nil)

            {:ok, :duplicate, contact}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  The daily pass. Returns `%{charged: n, reminded: n, released: n}`.
  `:now` pins the clock.
  """
  @spec collect(keyword()) :: %{
          charged: non_neg_integer(),
          reminded: non_neg_integer(),
          released: non_neg_integer()
        }
  def collect(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    if charging?() do
      due = due_contacts(now)

      charged =
        Enum.count(due, &match?({:ok, %Contact{}}, charge(&1, period_start(&1, now), now: now)))

      overdue = overdue_contacts(now)
      released = Enum.count(overdue, &release_if_expired(&1, now))
      reminded = overdue |> Enum.reject(&expired?(&1, now)) |> Enum.count(&remind(&1, now))
      %{charged: charged, reminded: reminded, released: released}
    else
      %{charged: 0, reminded: 0, released: 0}
    end
  end

  # A contact never charged (provisioned before rent existed) starts its
  # first month at the sweep, not at provisioning: the tenant was not told
  # about rent then, and back-charging months would be the phase 5 trap.
  defp period_start(%Contact{rent_paid_through: nil}, now), do: truncate(now)
  defp period_start(%Contact{rent_paid_through: at}, _now), do: at

  defp due_contacts(now) do
    from(c in Contact,
      where: is_nil(c.rent_paid_through) or c.rent_paid_through <= ^now,
      where: is_nil(c.rent_due_at),
      order_by: [asc: c.inserted_at]
    )
    |> Repo.all()
  end

  defp overdue_contacts(now) do
    from(c in Contact, where: not is_nil(c.rent_due_at) and c.rent_due_at <= ^now)
    |> Repo.all()
  end

  defp expired?(%Contact{rent_due_at: due}, now),
    do: DateTime.diff(now, due, :second) >= @grace_days * 86_400

  defp release_if_expired(%Contact{} = contact, now) do
    if expired?(contact, now) do
      # One more try first: a top-up during the grace pays the rent and
      # keeps the number.
      case charge(contact, period_start(contact, now), now: now) do
        {:ok, %Contact{}} ->
          false

        _ ->
          case Comms.release_contact(contact.user_id, contact.agent_id,
                 actor: "system:credit_rent"
               ) do
            :ok ->
              Logger.info(
                "credit rent: released contact #{contact.id} after #{@grace_days} days unpaid"
              )

              true

            {:error, reason} ->
              Logger.warning("credit rent: could not release #{contact.id}: #{inspect(reason)}")
              false
          end
      end
    else
      false
    end
  end

  # Days 0, 3 and 6 of the grace. The worker's uniqueness (two days per
  # contact and day) is what stops a daily sweep sending day 0 twice.
  defp remind(%Contact{} = contact, now) do
    # Pay first if the balance has come back; the reminder is then moot.
    case charge(contact, period_start(contact, now), now: now) do
      {:ok, %Contact{}} ->
        false

      _ ->
        day = div(DateTime.diff(now, contact.rent_due_at, :second), 86_400)

        if day in @reminder_days do
          days_left = @grace_days - day
          Fountain.Workers.CreditsEmail.enqueue_rent_due(contact.user_id, contact.id, days_left)
          true
        else
          false
        end
    end
  end

  defp stamp(%Contact{} = contact, changes) do
    contact |> Ecto.Changeset.change(changes) |> Repo.update()
  end

  @doc "One calendar month on, clamped to the shorter month's last day."
  @spec add_month(DateTime.t()) :: DateTime.t()
  def add_month(%DateTime{} = at) do
    date = DateTime.to_date(at)
    {y, m} = if date.month == 12, do: {date.year + 1, 1}, else: {date.year, date.month + 1}
    day = min(date.day, Date.days_in_month(Date.new!(y, m, 1)))
    {:ok, next} = DateTime.new(Date.new!(y, m, day), DateTime.to_time(at), "Etc/UTC")
    truncate(next)
  end

  defp truncate(dt), do: DateTime.truncate(dt, :second)

  @doc false
  def grace_days, do: @grace_days
end
