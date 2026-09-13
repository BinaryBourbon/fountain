defmodule Fountain.InferenceCredentials.Source do
  @moduledoc """
  Non-secret resolved inference identity, persisted on conversations and turns.

  `identity` identifies the owning source and credential kind; `revision`
  distinguishes replacement within that source. Neither contains bearer material.
  A default change affects new selections only. Existing peers must match their
  stored binding before preparing auth or starting another turn.
  """
  @type t :: %__MODULE__{}
  @enforce_keys [:origin, :scope]
  defstruct [
    :origin,
    :scope,
    :kind,
    :identity,
    :revision,
    :set_id,
    :runtime,
    :model,
    :environment_id,
    :vault_id
  ]

  def credential, do: %__MODULE__{origin: :own, scope: :credential}
  def tenant_secret, do: %__MODULE__{origin: :own, scope: :tenant_secret}
  def none, do: %__MODULE__{origin: :own, scope: :none}
  def platform, do: %__MODULE__{origin: :platform, scope: :platform}
  def missing, do: %__MODULE__{origin: :own, scope: :missing}
  def platform?(%__MODULE__{origin: :platform}), do: true
  def platform?(_), do: false

  def dump(nil), do: nil

  def dump(%__MODULE__{} = source) do
    source
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key),
       if(is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value)}
    end)
  end

  def load(nil), do: nil

  def load(%{} = source) do
    %__MODULE__{
      origin: decode(source["origin"], [:own, :platform]),
      scope: decode(source["scope"], [:credential, :tenant_secret, :platform, :none, :missing]),
      kind:
        decode(source["kind"], [
          :anthropic_api_key,
          :claude_code_oauth_token,
          :openai_api_key,
          :gemini_api_key,
          :codex_chatgpt_access_token
        ]),
      identity: source["identity"],
      revision: source["revision"],
      set_id: source["set_id"],
      runtime: source["runtime"],
      model: source["model"],
      environment_id: source["environment_id"],
      vault_id: source["vault_id"]
    }
  end

  defp decode(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
end
