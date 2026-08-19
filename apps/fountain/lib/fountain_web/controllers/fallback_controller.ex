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
    |> json(%{
      error: "vault_not_allowed",
      message: "vault is not in the agent's allowed_vault_ids"
    })
  end

  # Same two shapes for a per-launch environment override (#783).
  def call(conn, {:error, :environment_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "environment_not_found"})
  end

  def call(conn, {:error, :environment_not_allowed}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "environment_not_allowed",
      message: "environment is not in the agent's allowed_environment_ids"
    })
  end

  # An unknown or cross-tenant parent conversation. 404 rather than 403 so the
  # caller cannot use the response to probe which conversation ids exist.
  def call(conn, {:error, :parent_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "parent_conversation_not_found"})
  end

  # The agent pins a sandbox provider that is not usable on this instance
  # (its adapter is missing or its credentials were removed). 422 with the
  # provider named: an admin either configures the credentials or clears the
  # agent's override.
  def call(conn, {:error, {:sandbox_provider_disabled, provider}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "sandbox_provider_disabled",
      message:
        "sandbox provider #{provider} is not configured on this instance — " <>
          "set its credentials or clear the agent's sandbox_provider override"
    })
  end

  # The agent runs on the self-hosted runner provider (ADR 0022) and none of
  # the user's runners is connected right now. 409: nothing is misconfigured,
  # a machine just is not online — start `fountain runner` and retry.
  def call(conn, {:error, :no_runner_online}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: "no_runner_online",
      message:
        "this agent runs on a self-hosted runner and none of yours is connected — " <>
          "start `fountain runner` on the machine and try again"
    })
  end

  # Subscription gate (ADR 0006). Raised from the context so every provisioning
  # path renders the same response, rather than each controller inventing one.
  def call(conn, {:error, :subscription_required}) do
    conn
    |> put_status(:payment_required)
    |> json(%{error: "subscription_required", upgrade_url: "/account/billing"})
  end

  # Operator suspension (#287). 403 rather than 402: there is nothing the
  # caller can buy their way out of.
  def call(conn, {:error, :account_suspended}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "account_suspended"})
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

  # The ConversationServer did not answer within the call timeout — almost
  # always a server still inside handle_continue(:provision), whose blocked
  # mailbox makes every call wait the full 30s and exit (#412). 503 with
  # Retry-After rather than 500: the conversation is coming up, the request
  # was fine, and the caller should try again shortly.
  def call(conn, {:error, :provisioning}) do
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "provisioning",
      message: "the conversation is still provisioning; retry shortly"
    })
  end

  # The wake path could not reach the sandbox provider to check whether the
  # conversation's sandbox is still there (#799). Nothing was changed — the
  # row is deliberately left as it was rather than retired on a transport
  # error — so the caller should simply retry, same as :provisioning.
  def call(conn, {:error, :sprite_probe_failed}) do
    conn
    |> put_resp_header("retry-after", "10")
    |> put_status(:service_unavailable)
    |> json(%{
      error: "sandbox_probe_failed",
      message: "could not reach the sandbox provider to wake the conversation; retry shortly"
    })
  end

  # Prompting a terminated conversation. 410 rather than 404: the id was
  # real, the resource is gone for good, and the caller should stop retrying.
  def call(conn, {:error, :gone}) do
    conn
    |> put_status(:gone)
    |> json(%{error: "conversation_terminated"})
  end

  # The conversation's agent was deleted out from under it; it cannot resume.
  def call(conn, {:error, :no_agent}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "no_agent", message: "the conversation's agent has been deleted"})
  end

  # Billing is off on this instance (#524). 404 rather than 402/403: the
  # endpoint does not exist here, and the UI likewise redirects away from the
  # billing page entirely.
  def call(conn, {:error, :billing_disabled}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "billing_disabled", billing: "disabled"})
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: reason})
  end

  # Terminal safety net (#332): an error shape nothing above recognises.
  # Contexts grow new refusal atoms faster than controllers learn them, and
  # every miss used to be a CaseClauseError 500. A domain refusal is the
  # caller's problem, so 422 with the atom beats a blank 500 — and anything
  # that genuinely is a server fault still shows up in the logs below.
  def call(conn, {:error, reason}) when is_atom(reason) do
    require Logger
    Logger.warning("fallback: unmapped error atom #{inspect(reason)} on #{conn.request_path}")

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason)})
  end
end
