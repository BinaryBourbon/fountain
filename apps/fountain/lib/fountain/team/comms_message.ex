defmodule Fountain.Team.CommsMessage do
  @moduledoc """
  One teammate message that a provider charged for, and the row the credit
  ledger prices from (#1143).

  ## Why this exists rather than a `usage_events` row

  Comms messages used to be priced from `usage_events`. Those rows are written
  by `Fountain.Billing.record_usage/5`, which **rescues and logs** rather than
  failing the action that produced them — a metering outage must never fail a
  conversation. That contract is right for a count on a dashboard and wrong for
  a row the ledger keys on: a dropped `comms_*` event was a message the
  customer was never charged for, and nothing reconciled it afterwards, because
  the pricer's seven-day look-back only re-reads rows that already exist.

  So the money moved to a row of its own, written on the send path where a
  failure is visible. `usage_events` keeps the `comms_*` types for the product
  mirror, and is no longer what anything prices from.

  ## The idempotency key is the provider's

  `provider_message_id` is the id AgentMail or AgentPhone returned for this
  message, unique with `user_id` and `channel`. A send retried after a
  timeout that in fact reached the provider converges on one row instead of
  billing twice, and it is also the id to compare against when reconciling
  with a provider invoice — which is the comparison anybody auditing a bill
  would want to make anyway.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @channels ~w(email sms)
  @directions ~w(inbound outbound)

  @type t :: %__MODULE__{}

  schema "comms_messages" do
    field :user_id, :binary_id
    field :contact_id, :binary_id
    field :agent_id, :binary_id
    field :channel, :string
    field :direction, :string
    field :provider_message_id, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime
  end

  @doc "Both channels, for a caller that wants the vocabulary."
  def channels, do: @channels

  @doc "Both directions. Inbound counts: AgentPhone charges for a received SMS."
  def directions, do: @directions

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :user_id,
      :contact_id,
      :agent_id,
      :channel,
      :direction,
      :provider_message_id,
      :metadata,
      :inserted_at
    ])
    |> validate_required([:user_id, :channel, :direction, :provider_message_id, :inserted_at])
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:direction, @directions)
    |> unique_constraint([:user_id, :channel, :provider_message_id],
      name: :comms_messages_provider_id_index
    )
  end
end
