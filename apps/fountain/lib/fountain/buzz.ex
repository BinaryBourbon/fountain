defmodule Fountain.Buzz do
  @moduledoc """
  Context for Buzz identities and the environment a hosted `buzz-acp` runs with
  (ADR 0020, Phase 1 — tracker #735 / gate #736).

  A Buzz identity binds a Nostr keypair (in a vault) to a Fountain agent. This
  context owns the tenant-scoped CRUD for those bindings and the one function
  that turns a binding into a launch spec for `Fountain.Buzz.Harness`:
  `harness_launch/2` mints a scoped API key for the owner, decrypts the vault's
  `BUZZ_*` secrets **server-side**, and assembles the full process environment.

  The nsec never leaves the server: it goes from the vault into the harness
  process env, and the harness's ACP child (`fountain acp`) authenticates to
  this instance with the freshly-minted key — no human credentials file, and
  nothing about the identity travels into the sandbox.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.{Accounts, Audit, Crypto, Repo, Vaults}
  alias Fountain.Buzz.BuzzIdentity

  # ── identities (tenant-scoped) ─────────────────────────────────────────────

  @doc "WARNING: lookup by id without owner check. Admin/internal/supervisor use only."
  def _unsafe_get_identity(id), do: Repo.get(BuzzIdentity, id)

  @doc "List every enabled identity across tenants. System sweep only (the boot supervisor)."
  def _unsafe_list_enabled_identities do
    Repo.all(from i in BuzzIdentity, where: i.enabled == true)
  end

  @doc "List identities scoped to a user."
  def list_identities(user_id) when is_binary(user_id) do
    Repo.all(
      from i in BuzzIdentity,
        where: i.user_id == ^user_id,
        order_by: [desc: i.inserted_at, desc: i.id]
    )
  end

  @doc "Fetch one identity scoped to a user. Returns nil if missing or not owned."
  def get_identity(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.get_by(BuzzIdentity, id: id, user_id: user_id)
  end

  @doc """
  Create a Buzz identity. `attrs` must carry `user_id`, `agent_id`, `vault_id`,
  `name` and `relay_url`. Records `buzz_identity.created`.
  """
  def create_identity(attrs, opts \\ []) do
    %BuzzIdentity{}
    |> BuzzIdentity.changeset(attrs)
    |> Repo.insert()
    |> audited("buzz_identity.created", opts)
  end

  @doc "Update a Buzz identity. Records `buzz_identity.updated`."
  def update_identity(%BuzzIdentity{} = identity, attrs, opts \\ []) do
    identity
    |> BuzzIdentity.changeset(attrs)
    |> Repo.update()
    |> audited("buzz_identity.updated", opts)
  end

  @doc "Delete a Buzz identity. Records `buzz_identity.deleted`."
  def delete_identity(%BuzzIdentity{} = identity, opts \\ []) do
    identity
    |> Repo.delete()
    |> audited("buzz_identity.deleted", opts)
  end

  defp audited({:ok, %BuzzIdentity{} = identity} = ok, action, opts) do
    Audit.record(%{
      user_id: identity.user_id,
      action: action,
      resource_type: "buzz_identity",
      resource_id: identity.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      # Name and the *public* key identify which binding changed without
      # recording the secret — the nsec is never in this trail (ADR 0013).
      metadata: %{"name" => identity.name, "pubkey" => identity.pubkey}
    })

    ok
  end

  defp audited(other, _action, _opts), do: other

  # ── launch spec for the harness ────────────────────────────────────────────

  @typedoc """
  A `Fountain.Buzz.Harness` launch spec: the command, args, env, and the id of
  the API key minted for this run (so the caller/harness can revoke it on stop).

  * `:command` — path to the `buzz-acp` binary
  * `:args`    — argv (empty; `buzz-acp` is configured entirely by env)
  * `:env`     — `[{name, value}]` for the port
  * `:api_key_id` — the minted key's id, scoped to the owner, revoke on teardown
  """
  @type launch :: %{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          api_key_id: String.t()
        }

  @doc """
  Build the launch spec for a hosted `buzz-acp` bound to `identity`.

  Mints a `["sprite"]`-scoped API key for the owning user (the resource surface a
  sandbox-adjacent process needs, without key management), decrypts the vault's
  `BUZZ_PRIVATE_KEY` / `BUZZ_AUTH_TAG` / `BUZZ_RELAY_URL` server-side, and lays
  out the environment: the Buzz identity vars, the `BUZZ_ACP_*` wiring that
  points the harness's ACP child at `fountain acp --agent … --vault …`, and the
  `FOUNTAIN_*` vars that let that child authenticate back to this instance.

  Options:
  * `:buzz_acp_path` — path to the binary (defaults to app env `:buzz_acp_path`)
  * `:base_url`      — this instance's base URL for the ACP child
                       (defaults to app env `:public_base_url`)
  * `:fountain_bin`  — path to the `fountain` CLI in the harness image
                       (defaults to app env `:fountain_cli_path`, else `"fountain"`)
  * `:agents`        — `BUZZ_ACP_AGENTS` pool size (default 1; the desktop's 10 is
                       a desktop assumption)
  * `:actor` / `:request_ip` — attribution for the minted key's audit row

  Returns `{:ok, launch}` or `{:error, reason}`. The agent and vault referenced
  by the identity must exist; a caller that has already established ownership of
  the identity may call this — the mint is scoped to `identity.user_id`.
  """
  @spec harness_launch(BuzzIdentity.t(), keyword()) :: {:ok, launch()} | {:error, term()}
  def harness_launch(%BuzzIdentity{} = identity, opts \\ []) do
    command = opts[:buzz_acp_path] || Application.get_env(:fountain, :buzz_acp_path)
    base_url = opts[:base_url] || Application.get_env(:fountain, :public_base_url)

    fountain_bin =
      opts[:fountain_bin] || Application.get_env(:fountain, :fountain_cli_path) || "fountain"

    agents = opts[:agents] || 1

    cond do
      is_nil(command) ->
        {:error, :no_buzz_acp_path}

      is_nil(base_url) ->
        {:error, :no_base_url}

      true ->
        with {:ok, dek} <- Crypto.load_tenant_key(identity.user_id),
             {:ok, vault} <- fetch_vault(identity),
             {:ok, {key, raw}} <- mint_key(identity, opts) do
          vault_env = Vaults.decrypted_env(vault, dek)

          env =
            vault_env
            |> buzz_identity_env(identity)
            |> Map.merge(acp_wiring_env(identity, fountain_bin, agents))
            |> Map.merge(fountain_child_env(raw, base_url))
            |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

          {:ok, %{command: command, args: [], env: env, api_key_id: key.id}}
        end
    end
  end

  @doc """
  Revoke the API key a launch minted. Called when a harness stops so a
  one-conversation credential does not become standing access. Scoped to the
  identity's owner. Returns `{:ok, key}` or `{:error, :not_found}`.
  """
  def revoke_launch_key(%BuzzIdentity{} = identity, api_key_id, opts \\ []) do
    Accounts.revoke_api_key(identity.user_id, api_key_id, opts)
  end

  defp fetch_vault(%BuzzIdentity{vault_id: vault_id, user_id: user_id}) do
    # Ownership: the identity is tenant-owned and its vault_id is a same-tenant
    # FK, so a scoped fetch confirms it rather than trusting the pointer.
    case Vaults.get_vault(vault_id, user_id) do
      nil -> {:error, :vault_not_found}
      vault -> {:ok, vault}
    end
  end

  defp mint_key(%BuzzIdentity{} = identity, opts) do
    name = "buzz-acp:#{identity.name}"

    Accounts.create_api_key(identity.user_id, name,
      scopes: ["sprite"],
      actor: Keyword.get(opts, :actor, "system:buzz_harness"),
      request_ip: Keyword.get(opts, :request_ip)
    )
  end

  # The vault provides BUZZ_PRIVATE_KEY / BUZZ_AUTH_TAG (and may provide
  # BUZZ_RELAY_URL); the identity row is authoritative for the relay, so it wins.
  defp buzz_identity_env(vault_env, %BuzzIdentity{} = identity) do
    vault_env
    |> Map.put("BUZZ_RELAY_URL", identity.relay_url)
    |> maybe_put("BUZZ_ACP_DISPLAY_NAME", identity.display_name)
  end

  # Point the harness's ACP child at this Fountain agent + vault, and keep the
  # pool to one (the desktop's 10 is not our assumption).
  defp acp_wiring_env(%BuzzIdentity{} = identity, fountain_bin, agents) do
    args = "acp,--agent,#{identity.agent_id},--vault,#{identity.vault_id}"

    %{
      "BUZZ_ACP_AGENT_COMMAND" => fountain_bin,
      "BUZZ_ACP_AGENT_ARGS" => args,
      "BUZZ_ACP_AGENTS" => Integer.to_string(agents)
    }
  end

  # The ACP child authenticates back to this instance with the minted key.
  defp fountain_child_env(raw_key, base_url) do
    %{"FOUNTAIN_API_KEY" => raw_key, "FOUNTAIN_BASE_URL" => base_url}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
