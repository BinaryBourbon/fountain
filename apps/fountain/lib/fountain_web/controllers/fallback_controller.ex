defmodule FountainWeb.FallbackController do
  @moduledoc false
  use FountainWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: FountainWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  # start_conversation rejects an unknown / cross-tenant vault by returning
  # {:error, :vault_not_found}. Surface as 404 so callers can't tell the
  # difference between "no such vault" and "vault belongs to someone else".
  def call(conn, {:error, :vault_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "vault_not_found"})
  end

  # The agent's allowed_vault_ids forbids attaching this (existing, same-
  # tenant) vault. Unlike :vault_not_found this is a policy denial, so a
  # distinct status + message tells the caller which knob to look at.
  def call(conn, {:error, :vault_not_allowed}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "vault_not_allowed", message: "vault is not in the agent's allowed_vault_ids"})
  end

  # Subscription gate (ADR 0006). Raised from the context so every provisioning
  # path renders the same response, rather than each controller inventing one.
  def call(conn, {:error, :subscription_required}) do
    conn
    |> put_status(:payment_required)
    |> json(%{error: "subscription_required", upgrade_url: "/account/billing"})
  end

  # Per-tenant sandbox concurrency cap (ADR 0005). 429 rather than 402: this is
  # a rate/concurrency condition the caller can clear by terminating a
  # conversation, not a billing state they have to resolve by paying.
  def call(conn, {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}}) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{
      error: "sandbox_quota_exceeded",
      message:
        "You have #{count} of #{limit} concurrent sandboxes in use. " <>
          "Terminate a conversation before starting another.",
      active_sandboxes: count,
      limit: limit
    })
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: reason})
  end
end
