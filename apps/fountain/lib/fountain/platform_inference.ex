defmodule Fountain.PlatformInference do
  @moduledoc """
  The deployment's own inference keys, and the ceiling on what they may spend
  in a day (#1388, ADR 0038 decision 3, amending ADR 0008).

  Fountain holds a set of inference keys and runs a tenant's agent on one when
  the tenant has none of their own. The tenant's credential always wins; a
  deployment that configures no platform key behaves exactly as it did before
  this module existed, which is what makes it opt-in for a self-hoster.

  ## What is here

    * `enabled?/0` and `key_for/1` — the keys, from
      `PLATFORM_ANTHROPIC_API_KEY`, `PLATFORM_OPENAI_API_KEY` and
      `PLATFORM_GEMINI_API_KEY`. Blank is off, per provider.
    * `gate/2` — the door check: may this user's next conversation on this
      model start? `:ok` unless it would run on a platform key and the
      deployment has spent its day.
    * `check_ceiling/0` — the same ceiling without the "would it even use the
      platform key" question, for the per-turn backstop in
      `Conversations.TurnMachine.gate/2`, which already knows the answer.

  The *selection* rule lives in `Fountain.InferenceCredentials.select/2`, one
  function, because it is a statement about credentials rather than about
  money.

  ## The ceiling is a circuit breaker, not a quota

  `PLATFORM_INFERENCE_DAILY_CENTS` (default 5000, $50) bounds platform
  inference spend for the **whole deployment**, every tenant together, over a
  UTC day. It exists so one bad day cannot cost more than a number somebody
  wrote down. Hitting it is a 503, like `:fleet_full` — this is Fountain's
  limit, not the tenant's balance, and there is nothing they can buy to clear
  it (`FountainWeb.FallbackController`).

  Two properties worth knowing before trusting it:

    * **It is measured from the ledger**, so it lags `Workers.CreditPricer` by
      at most one tick. It bounds the day, not the minute.
    * **It needs `CREDITS_ENABLED=true`**, because that is what writes the
      ledger rows it reads. With credits off nothing is priced at all
      (ADR 0031), so nothing is counted and the ceiling never trips. A
      deployment that sets a platform key with credits off is paying its own
      inference bill knowingly and has no brake here.
  """

  require Logger

  @providers %{
    "anthropic" => {:anthropic_api_key, :platform_anthropic_api_key},
    "openai" => {:openai_api_key, :platform_openai_api_key},
    "google" => {:gemini_api_key, :platform_gemini_api_key}
  }

  @doc "Whether this deployment holds a platform key for any provider at all."
  @spec enabled?() :: boolean()
  def enabled?, do: Enum.any?(@providers, fn {provider, _} -> key_for(provider) != :none end)

  @doc """
  The providers this deployment holds a key for, in `Managoat.Runtimes.Model`
  order. For the admin surfaces and the docs test; never a gate.
  """
  @spec configured_providers() :: [String.t()]
  def configured_providers do
    Enum.filter(Managoat.Runtimes.Model.providers(), &(key_for(&1) != :none))
  end

  @doc """
  The platform key for a provider: `{:ok, credential, key}` — the credential
  atom `Fountain.InferenceCredentials` uses for it, so the value drops into
  the same map a tenant's own key lives in — or `:none`.

  A blank value is `:none`, not an empty key: an unset variable and a variable
  set to `""` are the same statement, and the second is what a Helm chart
  with no value produces.
  """
  @spec key_for(String.t() | nil) :: {:ok, atom(), String.t()} | :none
  def key_for(provider) when is_binary(provider) do
    case Map.get(@providers, provider) do
      nil ->
        :none

      {credential, config_key} ->
        case Application.get_env(:fountain, config_key) do
          key when is_binary(key) and key != "" -> {:ok, credential, key}
          _ -> :none
        end
    end
  end

  def key_for(_provider), do: :none

  @doc """
  The daily ceiling in cents (`PLATFORM_INFERENCE_DAILY_CENTS`, default 5000).
  """
  @spec daily_ceiling_cents() :: non_neg_integer()
  def daily_ceiling_cents do
    case Application.get_env(:fountain, :platform_inference_daily_cents) do
      cents when is_integer(cents) and cents >= 0 -> cents
      _ -> 5_000
    end
  end

  @doc """
  The door check, at every place a conversation begins: `:ok`, or
  `{:error, :platform_inference_unavailable}`.

  Three questions, cheapest first, so a deployment with no platform key runs
  no query at all:

    1. does this deployment hold a key for the model's provider?
    2. would this user actually take it — that is, do they have none of their
       own for that provider?
    3. has the deployment spent its day?

  Only a "yes" to all three refuses.
  """
  @spec gate(binary(), String.t() | nil) :: :ok | {:error, :platform_inference_unavailable}
  def gate(user_id, model) when is_binary(user_id) do
    provider = Managoat.Runtimes.Model.provider(model)

    if key_for(provider) != :none and not Fountain.InferenceCredentials.has_own?(user_id, model) do
      check_ceiling()
    else
      :ok
    end
  end

  @doc """
  The ceiling on its own, for a caller that already knows the turn runs on a
  platform key.

  `:ok` when credits are off (nothing is counted), when the ceiling is zero
  (which reads as "unbounded" the way `SANDBOX_CAP_CEILING` does not — see
  below), or when the day's spend is under it.
  """
  @spec check_ceiling() :: :ok | {:error, :platform_inference_unavailable}
  def check_ceiling do
    ceiling = daily_ceiling_cents()

    # Zero is "no platform inference today", not "unbounded": the variable
    # exists to bound spend, so the degenerate value has to bound it hardest.
    # An operator who wants the feature off unsets the keys.
    spent = Fountain.Billing.platform_inference_spend_today()

    cond do
      is_nil(spent) ->
        :ok

      spent < ceiling ->
        :ok

      true ->
        Logger.warning(
          "platform inference: daily ceiling reached (#{spent} of #{ceiling} cents); " <>
            "refusing conversations that would run on a platform key until UTC midnight"
        )

        {:error, :platform_inference_unavailable}
    end
  end
end
