defmodule Fountain.Webhooks.Delivery do
  @moduledoc """
  One HTTP attempt at one event, kept so "your webhook is broken" is a
  screenshot rather than a support thread.

  One row per attempt, not per event: the interesting question is usually
  "what did it say the first three times", and collapsing attempts loses it.
  Pruned by `Fountain.Workers.RetentionPruner` on the `webhook_deliveries`
  window.

  `response_body` is truncated at `max_body_bytes/0`. A receiver that streams
  us a gigabyte should cost us a few kilobytes of row, and the body is kept
  for diagnosis, not for content.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Enough to hold a stack trace or a JSON error, nowhere near enough to be
  # worth exfiltrating anything into.
  @max_body_bytes 4_096

  @type t :: %__MODULE__{}

  @doc "How much of a response body is kept."
  def max_body_bytes, do: @max_body_bytes

  schema "webhook_deliveries" do
    field :event_id, :string
    field :event_type, :string
    field :attempt, :integer, default: 1
    field :status_code, :integer
    field :duration_ms, :integer
    field :error, :string
    field :response_body, :string
    field :payload, :map, default: %{}
    belongs_to :webhook_endpoint, Fountain.Webhooks.Endpoint
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :webhook_endpoint_id,
      :event_id,
      :event_type,
      :attempt,
      :status_code,
      :duration_ms,
      :error,
      :response_body,
      :payload
    ])
    |> validate_required([:webhook_endpoint_id, :event_id, :event_type, :attempt])
    |> update_change(:response_body, &truncate/1)
    |> update_change(:error, &truncate_error/1)
  end

  @doc "Whether this attempt was accepted by the receiver."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{status_code: code}) when is_integer(code), do: code in 200..299
  def ok?(_), do: false

  defp truncate(nil), do: nil

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > @max_body_bytes do
      # Cut on a codepoint boundary so the stored value is still valid UTF-8
      # and a JSON encoder does not fail on the row later.
      body |> binary_part(0, @max_body_bytes) |> String.chunk(:valid) |> List.first() || ""
    else
      body
    end
  end

  defp truncate_error(nil), do: nil
  defp truncate_error(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
end
