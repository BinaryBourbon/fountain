defmodule FountainWeb.ClaimableUserJSON do
  @moduledoc """
  JSON views for claimable principals (ADR 0044).

  `principal_id` is rendered rather than `user_id`: it is the id an
  application holds on to, and calling it a user id invites the reading that
  claiming swaps one for another. It does not.
  """

  alias Fountain.Principals.ClaimableUser

  def show(%{claimable: claimable}), do: %{data: grant(claimable)}

  def created(%{claimable: claimable, api_key: raw, claim_token: token}) do
    %{data: grant(claimable) |> Map.merge(%{api_key: raw, claim_token: token})}
  end

  def claimed(%{claimable: claimable, api_key: raw, user: user}) do
    %{
      data: %{
        user: %{id: user.id, email: user.email},
        principal_id: claimable.user_id,
        status: claimable.status,
        claimed_at: claimable.claimed_at,
        api_key: raw
      }
    }
  end

  defp grant(%ClaimableUser{} = c) do
    %{
      id: c.id,
      principal_id: c.user_id,
      application_id: c.application_id,
      status: c.status,
      expires_at: c.expires_at,
      claimed_at: c.claimed_at,
      claimed_by_user_id: c.claimed_by_user_id,
      budget_exhausted_at: c.budget_exhausted_at,
      grant_cents: c.grant_cents,
      max_live_sandboxes: c.max_live_sandboxes,
      metadata: c.metadata,
      created_at: c.inserted_at
    }
  end
end
