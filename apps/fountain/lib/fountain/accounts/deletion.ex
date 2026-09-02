defmodule Fountain.Accounts.Deletion do
  @moduledoc """
  Closing an account and removing the tenant's data.

  The decisions here — ordering, crypto-shred scope and its backup boundary,
  Stripe customer retention, no soft-delete — are recorded in ADR 0009
  (`decisions/0009-account-deletion-and-export.md`). Change them there first.

  There was no deletion path at all — no self-serve, no admin, no context
  function — so a departing user's only options were to stop using the service
  while continuing to be billed, or to ask an operator to edit the database.

  ## Order matters

  1. **Destroy the tenant's sprites.** Before the row deletion, because the
     cascade takes `conversations` with it, and after that nothing links a
     sandbox to the user who was paying for it. Failures here are logged rather
     than fatal: `SandboxReaper` reconciles anything missed on its next run,
     which is exactly the case it exists for.

  2. **Record the audit event.** Before the delete, and carrying the email and
     user id in `metadata` — `audit_events.user_id` is `SET NULL` on delete, so
     an event that relies on the column alone would survive as an anonymous row
     saying an account was deleted, without saying which.

  3. **Delete the user.** Postgres cascades take agents, api_keys,
     conversations (and their turns and log events), environments, vaults,
     oauth_identities, inference_credentials and user_data_keys.
     `usage_events`, `audit_events` and `sandboxes` nilify instead, keeping
     operational and financial history that no longer names anybody.

  ## Crypto-shred

  Deleting `user_data_keys` destroys the wrapped per-tenant DEK, and every
  environment and vault secret is encrypted with it. So even ciphertext that
  outlives the cascade — a row missed by a future schema change, a stray copy —
  becomes undecryptable rather than merely unreferenced.

  That property is real but bounded: it does not reach **database backups**
  taken before the deletion, which contain both the ciphertext and the wrapped
  key. Backup expiry is what erases those, and it runs on its own retention
  schedule.

  ## Stripe

  Nothing is cancelled, because nothing recurs (ADR 0031): a prepaid balance
  goes with the row and its ledger. The Stripe customer is not deleted.
  Charges and refunds are financial records a business is required to
  retain, and Stripe is the system of record for them.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Conversations.{ConversationServer, Sandbox}
  alias Fountain.{Audit, Conversations, Repo}

  # Includes `suspended`: parked sprites are excluded from the concurrency
  # quota but still exist at sprites.dev, and deletion nilifies user_id — a
  # sprite missed here is unfindable afterward, a permanent leak.
  @non_terminal ~w(pending starting ready suspended)

  @doc """
  Delete `user` and everything belonging to them.

  Options:

    * `:actor` — who performed it, for the audit trail. Defaults to `"self"`;
      an admin path should pass something identifying.
    * `:request_ip` — passed through to the audit event.

  Returns `{:ok, summary}`. Nothing aborts before destruction: there is no
  subscription to cancel first (ADR 0031), and the Stripe customer stays for
  the refund trail.
  """
  @spec delete_user(User.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_user(%User{} = user, opts \\ []) do
    sprites = destroy_sprites(user)

    Audit.record(%{
      user_id: user.id,
      action: "account.deleted",
      resource_type: "user",
      resource_id: user.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      # Denormalised on purpose: user_id is nilified by the delete below.
      metadata: %{
        "email" => user.email,
        "user_id" => user.id,
        "sprites_destroyed" => sprites
      }
    })

    case Repo.delete(user) do
      {:ok, _} ->
        Logger.info("account deleted: #{user.id} (#{sprites} sprite(s) destroyed)")

        # Confirmation to the departing user (#450). Gated on verification,
        # which covers the UnverifiedAccountPruner path for free — an
        # address that never proved it was theirs gets no mail from us,
        # whoever triggered the deletion. The job carries the address
        # itself; the row is already gone.
        if user.email_verified_at do
          Fountain.Workers.AccountEmail.enqueue_deleted(user.email)
        end

        {:ok, %{user_id: user.id, sprites_destroyed: sprites}}

      {:error, reason} ->
        Logger.error("account deletion failed at delete for #{user.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── sprites ───────────────────────────────────────────────────────────────

  # Ask a live ConversationServer to tear itself down where one exists, so the
  # sprite goes through the same path as a user-initiated terminate. Otherwise
  # destroy the sprite directly.
  defp destroy_sprites(%User{id: user_id}) do
    conv_ids =
      Conversations.list_conversations(user_id)
      |> Enum.filter(&(ConversationServer.whereis(&1.id) != nil))
      |> Enum.map(& &1.id)

    Enum.each(conv_ids, fn id ->
      try do
        # No per-conversation row: `account.deleted` already says everything
        # went away, and the user_id these would carry is nilified moments
        # later anyway — they would be orphans describing a cascade.
        ConversationServer.terminate_conversation(id, audit: false)
      catch
        kind, reason ->
          Logger.warning("account deletion: terminate #{id} failed: #{inspect({kind, reason})}")
      end
    end)

    Sandbox
    |> where([s], s.user_id == ^user_id and s.status in ^@non_terminal)
    |> Repo.all()
    |> Enum.count(&destroy_sprite/1)
  end

  defp destroy_sprite(%Sandbox{sprite_name: name} = sandbox) when is_binary(name) do
    # The row's provider, never the instance default: a sandbox is destroyed
    # on the backend that holds it (ADR 0018), and this path used to hardcode
    # :sprites, which "destroyed" E2B/Daytona/runner sandboxes against the
    # wrong adapter.
    provider = Fountain.Conversations.sandbox_provider_atom(sandbox)
    handle = Managoat.Sandbox.build_handle(provider, name)

    result =
      case Managoat.Sandbox.destroy(handle) do
        :ok ->
          true

        {:error, reason} ->
          # Not fatal. SandboxReaper reconciles terminal rows whose sprite still
          # exists, which is precisely this leftover.
          Logger.warning("account deletion: destroy #{name} failed: #{inspect(reason)}")
          false
      end

    Conversations.update_sandbox(sandbox, %{
      status: "terminated",
      terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    result
  rescue
    e ->
      Logger.warning("account deletion: destroy raised for #{name}: #{inspect(e)}")
      false
  end

  defp destroy_sprite(_), do: false
end
