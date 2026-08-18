defmodule FountainWeb.BuzzAgentController do
  @moduledoc """
  Provision and manage hosted Buzz agents over the API (ADR 0020 Phase 3, #738).

  This is the Fountain-side surface the `buzz-backend-fountain` remote-agents
  provider calls: `create` maps onto a provider `deploy` (idempotent on the
  Nostr pubkey), and `delete` tears the hosted agent down. The Nostr secret key
  is accepted on `create` and stored server-side in the identity's vault; it is
  never returned and never enters a sandbox.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Buzz
  alias Fountain.Buzz.{BuzzIdentity, Manager}
  alias Fountain.Vaults
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Buzz"])

  operation(:index,
    summary: "List hosted Buzz agents",
    responses: [ok: {"Buzz agents", "application/json", Schemas.BuzzIdentityListResponse}]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{data: Enum.map(Buzz.list_identities(user.id), &identity_json/1)})
  end

  operation(:create,
    summary: "Provision (or converge on) a hosted Buzz agent",
    request_body: {"Provision attributes", "application/json", Schemas.BuzzProvisionRequest},
    responses: [
      created: {"Buzz agent", "application/json", Schemas.BuzzIdentityResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs =
      Map.take(
        params,
        ~w(name relay_url agent_id pubkey private_key_nsec auth_tag display_name environment_id
           respond_to respond_to_allowlist)
      )

    # A converging deploy may change what the harness was launched with; the
    # identity as it was before tells us whether the running one must bounce.
    before = Buzz.get_identity_by_pubkey(params["pubkey"] || "", user.id)

    case Buzz.provision_identity(user.id, attrs, actor: "api") do
      {:ok, %BuzzIdentity{} = identity} ->
        # Best-effort eager start so a provider `deploy` sees it running; the
        # boot sweep also stands enabled identities up, so this is not load-bearing.
        # When the deploy changed a launch-relevant field (author gate, environment,
        # relay, name — #790) the harness restarts so the new env takes effect.
        _ = ensure_harness(before, identity)

        conn
        |> put_status(:created)
        |> json(%{data: identity_json(identity)})

      {:error, {:missing, fields}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "missing required fields: #{Enum.join(fields, ", ")}"})

      # 404 like every other unknown-or-foreign environment id, so the response
      # cannot be used to probe which ids exist.
      {:error, :environment_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "environment_not_found"})

      # Field errors — an empty allowlist in allowlist mode, a malformed pubkey —
      # so a provider deploy can say *why* it was refused, not a bare 422.
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "could not provision the buzz agent"})
    end
  end

  operation(:update,
    summary: "Change who may talk to a hosted Buzz agent",
    parameters: [id: [in: :path, type: :string, description: "Buzz agent id"]],
    request_body: {"Access attributes", "application/json", Schemas.BuzzAccessUpdateRequest},
    responses: [
      ok: {"Buzz agent", "application/json", Schemas.BuzzIdentityResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  # The operator's knob for the inbound author gate (#790): sets `respond_to`
  # / `respond_to_allowlist` on the identity and restarts its harness so the
  # new gate is live. Exists because the desktop refuses to change access on a
  # provider agent it has already deployed, so the record's policy cannot be
  # resent from there.
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %BuzzIdentity{} = identity <- Buzz.get_identity(id, user.id),
         {:ok, %BuzzIdentity{} = updated} <-
           Buzz.update_access(identity, Map.take(params, ~w(respond_to respond_to_allowlist)),
             actor: "api"
           ) do
      if Buzz.launch_config_changed?(identity, updated), do: Manager.restart_harness(updated)
      json(conn, %{data: identity_json(updated)})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :nothing_to_update} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "nothing to update: send respond_to and/or respond_to_allowlist"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  operation(:delete,
    summary: "Tear down a hosted Buzz agent",
    parameters: [id: [in: :path, type: :string, description: "Buzz agent id"]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Buzz.get_identity(id, user.id) do
      %BuzzIdentity{} = identity ->
        Manager.stop_harness(identity.id)
        {:ok, _} = Buzz.delete_identity(identity, actor: "api")
        delete_vault(identity, user.id)
        send_resp(conn, :no_content, "")

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp ensure_harness(%BuzzIdentity{} = before, %BuzzIdentity{} = identity) do
    if Buzz.launch_config_changed?(before, identity),
      do: Manager.restart_harness(identity),
      else: Manager.start_harness(identity)
  end

  defp ensure_harness(nil, %BuzzIdentity{} = identity), do: Manager.start_harness(identity)

  defp delete_vault(%BuzzIdentity{vault_id: vault_id}, user_id) do
    case Vaults.get_vault(vault_id, user_id) do
      %Vaults.Vault{} = vault -> Vaults.delete_vault(vault, actor: "api")
      _ -> :ok
    end
  end

  defp identity_json(%BuzzIdentity{} = i) do
    %{
      id: i.id,
      name: i.name,
      display_name: i.display_name,
      relay_url: i.relay_url,
      pubkey: i.pubkey,
      agent_id: i.agent_id,
      vault_id: i.vault_id,
      environment_id: i.environment_id,
      respond_to: i.respond_to,
      respond_to_allowlist: i.respond_to_allowlist,
      enabled: i.enabled,
      inserted_at: i.inserted_at,
      updated_at: i.updated_at
    }
  end
end
