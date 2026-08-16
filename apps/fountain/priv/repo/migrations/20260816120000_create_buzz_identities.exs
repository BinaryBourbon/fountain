defmodule Fountain.Repo.Migrations.CreateBuzzIdentities do
  use Ecto.Migration

  # A Buzz identity is the fifth-and-a-half thing: not one of the four
  # primitives, but the binding that lets Fountain host a Buzz agent's Nostr
  # presence (ADR 0020). It points a Nostr keypair (held as vault secrets, not
  # here) at a Fountain agent, so a hosted `buzz-acp` can run the agent off the
  # user's desktop. The nsec never lives in this row — only the public identity
  # and the pointers do; `BUZZ_PRIVATE_KEY` / `BUZZ_AUTH_TAG` stay in the vault,
  # decrypted server-side at harness start.
  def change do
    create table(:buzz_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # The Fountain agent this identity drives, and the vault carrying its
      # BUZZ_* secrets. Nilifying rather than cascading on delete would leave a
      # harness with no agent to run or no key to sign with, so both cascade the
      # identity away with their target.
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :relay_url, :string, null: false
      # The Nostr public key (hex). The public half of the identity — safe to
      # store, and the natural uniqueness key per tenant.
      add :pubkey, :string
      add :display_name, :string

      # Whether the boot sweep should stand a harness up for this identity.
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:buzz_identities, [:user_id])

    create unique_index(:buzz_identities, [:user_id, :name],
             name: "buzz_identities_user_id_name_index"
           )

    # A pubkey is one identity per tenant when known; NULL pubkeys (not yet
    # resolved from the key) don't collide.
    create unique_index(:buzz_identities, [:user_id, :pubkey],
             where: "pubkey IS NOT NULL",
             name: "buzz_identities_user_id_pubkey_index"
           )
  end
end
