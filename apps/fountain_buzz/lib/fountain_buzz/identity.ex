defmodule FountainBuzz.Identity do
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

  It also carries the harness's **inbound author gate** (#790): `respond_to` is
  one of `buzz-acp`'s `--respond-to` modes and `respond_to_allowlist` the
  pubkeys admitted in `allowlist` mode. These become `BUZZ_ACP_RESPOND_TO` /
  `BUZZ_ACP_RESPOND_TO_ALLOWLIST` in the harness env — the same translation the
  desktop performs when it spawns `buzz-acp` itself. The default is `owner-only`,
  which is also the harness's own default, so an identity that never set a
  policy behaves as before.
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

  @respond_to_modes ~w(owner-only allowlist anyone nobody)

  @doc "The `buzz-acp` `--respond-to` modes an identity may carry."
  def respond_to_modes, do: @respond_to_modes

  schema "buzz_identities" do
    field :name, :string
    field :relay_url, :string
    field :pubkey, :string
    field :display_name, :string
    field :enabled, :boolean, default: true
    field :respond_to, :string, default: "owner-only"
    field :respond_to_allowlist, {:array, :string}, default: []
    # Where this identity's conversations run (ADR 0023): `ephemeral`,
    # `persistent`, or nil for the agent's own default.
    field :sandbox_mode, :string

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
    :respond_to,
    :respond_to_allowlist,
    :sandbox_mode,
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
    |> validate_inclusion(:respond_to, @respond_to_modes)
    |> validate_inclusion(:sandbox_mode, Fountain.Agents.Agent.sandbox_modes())
    |> validate_respond_to_allowlist()
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

  # The allowlist is only meaningful in `allowlist` mode, where buzz-acp refuses
  # to start without at least one entry — catch that here rather than in a
  # crash loop. Every entry is a 64-hex pubkey, as buzz-acp validates them.
  defp validate_respond_to_allowlist(changeset) do
    mode = get_field(changeset, :respond_to)
    list = get_field(changeset, :respond_to_allowlist) || []

    changeset
    |> validate_change(:respond_to_allowlist, fn :respond_to_allowlist, entries ->
      if Enum.all?(entries, &(&1 =~ ~r/\A[0-9a-f]{64}\z/)) do
        []
      else
        [respond_to_allowlist: "every entry must be a 64 lowercase hex pubkey"]
      end
    end)
    |> then(fn cs ->
      if mode == "allowlist" and list == [] do
        add_error(cs, :respond_to_allowlist, "must name at least one pubkey in allowlist mode")
      else
        cs
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
