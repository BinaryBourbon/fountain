defmodule FountainWeb.WebhookEndpointJSON do
  @moduledoc """
  JSON views for webhook endpoints and their delivery log.

  The signing secret appears in exactly one view, `created/1`, and it is the
  only place it ever appears — the column is encrypted rather than hashed
  because the delivery worker has to sign with it, not because anyone else
  should read it back.
  """

  alias Fountain.Webhooks.{Delivery, Endpoint}

  @doc "The endpoint plus its plaintext secret. Shown once, at create and at rotate."
  def created(%{endpoint: %Endpoint{} = endpoint, secret: secret}) do
    %{data: summary(endpoint), secret: secret}
  end

  def index(%{endpoints: endpoints}), do: %{data: Enum.map(endpoints, &summary/1)}

  def show(%{endpoint: %Endpoint{} = endpoint}), do: %{data: summary(endpoint)}

  def deliveries(%{deliveries: deliveries}),
    do: %{data: Enum.map(deliveries, &delivery/1)}

  def test(%{event_type: event_type}), do: %{queued: true, event_type: event_type}

  defp summary(%Endpoint{} = endpoint) do
    %{
      id: endpoint.id,
      url: endpoint.url,
      description: endpoint.description,
      event_types: endpoint.event_types,
      status: endpoint.status,
      consecutive_failures: endpoint.consecutive_failures,
      disabled_at: endpoint.disabled_at,
      disabled_reason: endpoint.disabled_reason,
      inserted_at: endpoint.inserted_at,
      updated_at: endpoint.updated_at
    }
  end

  defp delivery(%Delivery{} = delivery) do
    %{
      id: delivery.id,
      event_id: delivery.event_id,
      event_type: delivery.event_type,
      attempt: delivery.attempt,
      status_code: delivery.status_code,
      duration_ms: delivery.duration_ms,
      error: delivery.error,
      response_body: delivery.response_body,
      inserted_at: delivery.inserted_at
    }
  end
end
