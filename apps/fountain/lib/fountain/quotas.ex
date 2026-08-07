defmodule Fountain.Quotas do
  @moduledoc """
  Per-tenant resource caps.

  Fountain provisions every tenant's sandboxes with a single platform-level
  `SPRITES_TOKEN` and pays the resulting bill (ADR 0005), so a per-tenant
  concurrency cap is the primary defence against one account — whether abusive,
  scripted, or merely enthusiastic — consuming the platform's capacity.

  The cap is `users.max_concurrent_sandboxes` (default 5) and is admin-adjustable
  per user: raise it for a trusted tenant, lower it during abuse.

  ## What counts

  A sandbox is "active" while its status is anything other than `terminated` or
  `failed`, matching the definition used by the admin sandbox view. `pending`
  and `starting` both count: a sprite is being paid for from the moment
  provisioning begins, and counting only `ready` would let a burst of concurrent
  starts sail past the cap before any of them settle.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  @default_limit 5
  @active_statuses ~w(pending starting ready)

  defmodule QuotaExceededError do
    @moduledoc "Raised by `Fountain.Quotas.check_sandbox_quota!/2`."
    defexception [:message, :limit, :count]
  end

  @doc """
  Number of sandboxes currently counting against `user_id`'s cap.

  Pass `exclude: sandbox_id` to leave a specific sandbox out. The wake path
  needs this: it provisions the replacement before retiring the sandbox it is
  replacing, so without the exclusion a conversation sitting exactly at the cap
  could never be woken even though concurrency would not increase.
  """
  @spec active_sandbox_count(binary(), keyword()) :: non_neg_integer()
  def active_sandbox_count(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from s in Sandbox,
        where: s.user_id == ^user_id and s.status in @active_statuses,
        select: count(s.id)

    query =
      case Keyword.get(opts, :exclude) do
        nil -> query
        excluded -> from s in query, where: s.id != ^excluded
      end

    Repo.one(query) || 0
  end

  @doc """
  Active-sandbox counts for every user with at least one, in a single query —
  for the admin view, which refreshes on a timer and must not run a count per
  row (the same contract as `Fountain.Billing.usage_summaries/2`).

  Returns `%{user_id => count}`; users with no active sandboxes are absent.
  """
  @spec active_sandbox_counts() :: %{optional(binary()) => non_neg_integer()}
  def active_sandbox_counts do
    from(s in Sandbox,
      where: s.status in @active_statuses,
      group_by: s.user_id,
      select: {s.user_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The concurrency cap for `user_id`.

  Falls back to the default if the user is missing or the column is null, so a
  lookup failure tightens rather than removes the limit.
  """
  @spec sandbox_limit(binary()) :: non_neg_integer()
  def sandbox_limit(user_id) when is_binary(user_id) do
    case Repo.one(from u in User, where: u.id == ^user_id, select: u.max_concurrent_sandboxes) do
      nil -> @default_limit
      limit -> limit
    end
  end

  @doc """
  Check `user_id` against the sandbox concurrency cap.

  Returns `:ok`, or `{:error, {:sandbox_quota_exceeded, %{count: n, limit: n}}}`.

  Call this immediately before creating a sandbox row — every row precedes a
  `Sprites.create/2`, so guarding row creation guards sprite creation.
  """
  @spec check_sandbox_quota(binary(), keyword()) ::
          :ok
          | {:error,
             {:sandbox_quota_exceeded, %{count: non_neg_integer(), limit: non_neg_integer()}}}
  def check_sandbox_quota(user_id, opts \\ []) when is_binary(user_id) do
    limit = sandbox_limit(user_id)
    count = active_sandbox_count(user_id, opts)

    if count < limit do
      :ok
    else
      {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}}
    end
  end

  @doc """
  Raising variant of `check_sandbox_quota/2`, per ADR 0005.

  Prefer the non-raising form on request paths; this exists for call sites where
  exceeding the cap is a programming error rather than a user-facing outcome.
  """
  @spec check_sandbox_quota!(binary(), keyword()) :: :ok
  def check_sandbox_quota!(user_id, opts \\ []) when is_binary(user_id) do
    case check_sandbox_quota(user_id, opts) do
      :ok ->
        :ok

      {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}} ->
        raise QuotaExceededError,
          message:
            "sandbox concurrency limit reached (#{count}/#{limit} active). " <>
              "Terminate a conversation or ask an admin to raise max_concurrent_sandboxes.",
          count: count,
          limit: limit
    end
  end

  # Advisory-lock namespace for sandbox reservations; the second key is a hash
  # of the user id. A hash collision between users only over-serializes two
  # tenants' creations — never under-counts.
  @lock_namespace 4315

  @doc """
  Check the cap and run `fun` (which must create the sandbox row) atomically,
  under a per-user Postgres advisory lock.

  `check_sandbox_quota/2` alone is check-then-insert: N concurrent requests at
  the cap could each read `count < limit` before any row landed, and each go
  on to provision a paid sprite (#330). The lock serializes check + insert per
  user, so the second request re-counts after the first has committed. Scoped
  per user: one tenant's burst cannot queue behind another's.

  `fun` must return `{:ok, value}` or `{:error, reason}`; any error — the
  quota's or `fun`'s — rolls the whole reservation back.
  """
  @spec with_sandbox_reservation(binary(), keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_sandbox_reservation(user_id, quota_opts \\ [], fun) when is_binary(user_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @lock_namespace,
        :erlang.phash2(user_id)
      ])

      with :ok <- check_sandbox_quota(user_id, quota_opts),
           {:ok, value} <- fun.() do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Default cap applied when a user has none set."
  def default_limit, do: @default_limit

  @doc "Sandbox statuses that count against the cap."
  def active_statuses, do: @active_statuses
end
