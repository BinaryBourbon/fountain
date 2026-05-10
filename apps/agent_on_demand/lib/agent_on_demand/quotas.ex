defmodule AgentOnDemand.Quotas do
  @moduledoc """
  Enforces per-tenant resource limits.

  The primary noisy-neighbor mitigation per decision 0005: each tenant is
  capped at `users.max_concurrent_sandboxes` active sandboxes (default 5).
  Admins can raise or lower the cap per user.
  """

  import Ecto.Query, only: [from: 2]

  alias AgentOnDemand.Accounts
  alias AgentOnDemand.Conversations.Sandbox
  alias AgentOnDemand.Repo

  defmodule QuotaExceededError do
    @moduledoc "Raised when a tenant's sandbox concurrency cap is reached."
    defexception [:message, :user_id, :current_count, :max_count]

    @impl true
    def message(%{message: msg}), do: msg
  end

  @active_statuses ~w(pending starting ready)

  @doc """
  Asserts the user is below their concurrent sandbox limit.

  Raises `QuotaExceededError` if the count of sandboxes in
  `pending | starting | ready` status is at or above
  `user.max_concurrent_sandboxes`. Returns `:ok` otherwise.

  Called in `ConversationServer.init/1` before `Sprites.create/2`.

  ## Note
  `Accounts.get_user!/1` and `users.max_concurrent_sandboxes` are
  provided by the phase-3-foundation slice.
  """
  @spec check_sandbox_quota!(binary()) :: :ok
  def check_sandbox_quota!(user_id) do
    user = Accounts.get_user!(user_id)
    current = count_active_sandboxes(user_id)

    if current >= user.max_concurrent_sandboxes do
      raise QuotaExceededError,
        message:
          "sandbox quota exceeded for user #{user_id}: " <>
            "#{current}/#{user.max_concurrent_sandboxes} active sandboxes",
        user_id: user_id,
        current_count: current,
        max_count: user.max_concurrent_sandboxes
    end

    :ok
  end

  defp count_active_sandboxes(user_id) do
    Repo.one(
      from s in Sandbox,
        where: s.user_id == ^user_id and s.status in ^@active_statuses,
        select: count(s.id)
    )
  end
end
