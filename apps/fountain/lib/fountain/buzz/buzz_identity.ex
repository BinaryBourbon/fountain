defmodule Fountain.Buzz.BuzzIdentity do
  @moduledoc """
  A Buzz identity: the binding that lets Fountain host a Buzz agent's Nostr
  presence off the user's desktop (ADR 0020, Phase 1).

  It points a Nostr keypair — held as `BUZZ_PRIVATE_KEY` / `BUZZ_AUTH_TAG` in the
  referenced **vault**, never in this row — at a Fountain **agent**. A hosted
  `buzz-acp` supervised per identity runs that agent as its ACP child, so the
  agent keeps a body on the relay even when the laptop that created it is closed.

  The public key is stored (it is public); the secret is not. Deleting the user,
  the agent, or the vault cascades the identity away — a harness with no agent to
  run or no key to sign with is not a state worth keeping.

  An identity may also name an **environment** (#783): the baseline its
  conversations are provisioned from instead of the agent's own, so one agent
  config can run under N environments — one per identity. Optional; nil means
  the agent's environment, and deleting the environment nilifies rather than
  cascades, because losing an override is not losing the identity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "buzz_identities" do
    field :name, :string
    field :relay_url, :string
    field :pubkey, :string
    field :display_name, :string
    field :enabled, :boolean, default: true

    belongs_to :user, User
    belongs_to :agent, Agent
    belongs_to :vault, Vault
    belongs_to :environment, Environment

    timestamps(type: :utc_datetime)
  end

  @castable [
    :name,
    :relay_url,
    :pubkey,
    :display_name,
    :enabled,
    :user_id,
    :agent_id,
    :vault_id,
    :environment_id
  ]

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, @castable)
    |> validate_required([:name, :relay_url, :user_id, :agent_id, :vault_id])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_relay_url()
    |> validate_pubkey()
    |> unique_constraint(:name, name: :buzz_identities_user_id_name_index)
    |> unique_constraint(:pubkey, name: :buzz_identities_user_id_pubkey_index)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:vault_id)
    |> foreign_key_constraint(:environment_id)
  end

  # `buzz-acp` connects over a WebSocket, so the relay URL must be ws(s). A
  # http(s) URL is what the `buzz` CLI wants and a common paste error; reject it
  # here rather than letting the harness fail opaquely at connect time.
  defp validate_relay_url(changeset) do
    validate_change(changeset, :relay_url, fn :relay_url, url ->
      if String.starts_with?(url, "ws://") or String.starts_with?(url, "wss://") do
        []
      else
        [relay_url: "must be a ws:// or wss:// URL"]
      end
    end)
  end

  # A Nostr pubkey is 64 lowercase hex chars. NULL is allowed (not yet resolved).
  defp validate_pubkey(changeset) do
    validate_change(changeset, :pubkey, fn :pubkey, pubkey ->
      if is_nil(pubkey) or pubkey =~ ~r/\A[0-9a-f]{64}\z/ do
        []
      else
        [pubkey: "must be 64 lowercase hex characters"]
      end
    end)
  end
end
