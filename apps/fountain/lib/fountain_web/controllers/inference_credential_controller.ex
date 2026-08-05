defmodule FountainWeb.InferenceCredentialController do
  @moduledoc """
  Per-user inference provider credentials over the API (ADR 0008, #518).

  A conversation cannot run without one of these, and until now they could only
  be set in a browser — so an API-only consumer could register, create an agent,
  and then fail at the one step that matters. This is the same validate → encrypt
  path the settings LiveView uses, including the provider ping.

  Values are write-only: the API reports which providers are set and never
  returns a credential, decrypted or otherwise.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.InferenceCredentials.{Credential, Validator}
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  @providers Credential.providers()
  @provider_strings Enum.map(@providers, &Atom.to_string/1)

  tags(["Inference credentials"])

  operation(:index,
    summary: "List inference-credential status per provider",
    description:
      "Reports which providers have a credential set. Values are never returned — " <>
        "not even truncated.",
    responses: [
      ok: {"Provider status", "application/json", Schemas.InferenceCredentialListResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    status = InferenceCredentials.status_for_user(conn.assigns.current_user.id)
    render(conn, :index, status: status, providers: @providers)
  end

  operation(:update,
    summary: "Set a provider credential",
    description:
      "Validates the credential against the provider, then stores it encrypted " <>
        "under the tenant DEK. Set `validate: false` to skip the provider ping — " <>
        "useful when the provider is unreachable from this instance, at the cost " <>
        "of finding out about a typo mid-conversation instead of here.",
    parameters: [
      provider: [
        in: :path,
        type: %OpenApiSpex.Schema{type: :string, enum: @provider_strings},
        required: true
      ]
    ],
    request_body: {"Credential", "application/json", Schemas.InferenceCredentialRequest},
    responses: [
      ok: {"Provider status", "application/json", Schemas.InferenceCredentialResponse},
      bad_gateway: {"Provider unreachable", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      gateway_timeout: {"Provider timed out", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Rejected credential, blank value, or unknown provider", "application/json",
         Schemas.Error}
    ]
  )

  def update(conn, %{"provider" => provider_str} = params) do
    user = conn.assigns.current_user
    value = params |> Map.get("value") |> to_trimmed_string()

    with {:ok, provider} <- parse_provider(provider_str),
         :ok <- reject_empty(value),
         :ok <- validate_with_provider(provider, value, params) do
      persist(conn, user, provider, value)
    else
      # Provider-ping outcomes are distinguishable by design (#518): a rejected
      # credential is the caller's problem, a timeout or an unreachable provider
      # is not, and a client retrying blindly on 422 would burn quota for
      # nothing. The LiveView draws the same three distinctions in prose.
      {:error, :invalid, %{status: status}} ->
        error(conn, :unprocessable_entity, %{
          error: "the provider rejected this credential (HTTP #{status})",
          reason: "invalid",
          provider_status: status
        })

      {:error, :timeout} ->
        error(conn, :gateway_timeout, %{
          error: "validation timed out talking to the provider",
          reason: "timeout"
        })

      {:error, reason} when reason in [:empty_value, :empty] ->
        error(conn, :unprocessable_entity, %{error: "value is required", reason: "empty_value"})

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _network} ->
        error(conn, :bad_gateway, %{
          error: "could not reach the provider to validate this credential",
          reason: "network"
        })
    end
  end

  operation(:delete,
    summary: "Clear a provider credential",
    parameters: [
      provider: [
        in: :path,
        type: %OpenApiSpex.Schema{type: :string, enum: @provider_strings},
        required: true
      ]
    ],
    responses: [
      no_content: "Cleared",
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Unknown provider", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"provider" => provider_str}) do
    user = conn.assigns.current_user

    with {:ok, provider} <- parse_provider(provider_str),
         {:ok, dek} <- load_dek(user.id),
         {:ok, _cred} <- InferenceCredentials.put_credential(user.id, dek, provider, nil) do
      audit(conn, "inference_credential.delete", provider)
      send_resp(conn, :no_content, "")
    end
  end

  ## Private

  defp persist(conn, user, provider, value) do
    with {:ok, dek} <- load_dek(user.id),
         {:ok, _cred} <- InferenceCredentials.put_credential(user.id, dek, provider, value) do
      audit(conn, "inference_credential.write", provider)

      render(conn, :show,
        provider: provider,
        status: InferenceCredentials.status_for_user(user.id)
      )
    end
  end

  # The path parameter is an enum in the spec, so CastAndValidate refuses an
  # unknown provider (422) before the action runs. This clause is the
  # fail-closed backstop for a request that somehow arrives without it.
  defp parse_provider(provider_str) when provider_str in @provider_strings do
    {:ok, String.to_existing_atom(provider_str)}
  end

  defp parse_provider(_), do: {:error, :not_found}

  defp reject_empty(""), do: {:error, :empty_value}
  defp reject_empty(nil), do: {:error, :empty_value}
  defp reject_empty(_), do: :ok

  defp validate_with_provider(provider, value, params) do
    if Map.get(params, "validate", true) == false do
      :ok
    else
      Validator.validate(provider, value)
    end
  end

  defp load_dek(user_id) do
    case Crypto.load_tenant_key(user_id) do
      {:ok, dek} -> {:ok, dek}
      {:error, _reason} -> {:error, :tenant_key_unavailable}
    end
  end

  defp audit(conn, action, provider) do
    # The provider name is the whole payload — the credential itself must never
    # reach a second table.
    Audited.from_conn(conn, action, "inference_credential",
      resource_id: Atom.to_string(provider),
      metadata: %{"provider" => Atom.to_string(provider)}
    )
  end

  defp to_trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp to_trimmed_string(_), do: nil

  defp error(conn, status, body) do
    conn
    |> put_status(status)
    |> json(body)
  end
end
