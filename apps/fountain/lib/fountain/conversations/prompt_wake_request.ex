defmodule Fountain.Conversations.PromptWakeRequest do
  @moduledoc "A saved prompt's one wake invocation; a started request is never automatically replayed."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "prompt_wake_requests" do
    field :user_id, :binary_id
    field :conversation_id, :binary_id
    field :sandbox_id, :binary_id
    field :state, :string, default: "requested"
    field :started_at, :utc_datetime_usec
    field :returned_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
