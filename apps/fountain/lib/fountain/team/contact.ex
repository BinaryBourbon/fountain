defmodule Fountain.Team.Contact do
  @moduledoc """
  A teammate's email address and phone number — the AgentMail inbox and
  AgentPhone number Fountain provisioned for it (`Fountain.Team.Comms`).

  Keyed by `(user_id, agent_id)`, the pair that names a teammate, so it
  survives the teammate's conversation being replaced. Either channel may be
  absent (the provider declined, or was not configured) — `email?/1` and
  `phone?/1` say which the teammate actually has.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_contacts" do
    field :email_address, :string
    field :email_inbox_id, :string
    field :phone_number, :string
    field :phone_number_id, :string

    belongs_to :user, Fountain.Accounts.User
    belongs_to :agent, Fountain.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  @fields [:user_id, :agent_id, :email_address, :email_inbox_id, :phone_number, :phone_number_id]

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :agent_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint([:user_id, :agent_id])
  end

  def email?(%__MODULE__{email_inbox_id: id}), do: is_binary(id) and id != ""
  def phone?(%__MODULE__{phone_number_id: id}), do: is_binary(id) and id != ""
end
