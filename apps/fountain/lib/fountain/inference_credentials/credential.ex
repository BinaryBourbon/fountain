defmodule Fountain.InferenceCredentials.Credential do
  @moduledoc """
  Per-user inference provider credentials.

  Each row holds up to four encrypted credentials, one per supported provider:

  - `anthropic_api_key` — for the `claude` runtime (when no OAuth token is set)
    and for `opencode` runs against an `anthropic/...` model.
  - `claude_code_oauth_token` — preferred for the `claude` runtime; bills
    against a Claude.ai Pro/Team subscription instead of metered API usage.
  - `openai_api_key` — for the `codex` runtime and `opencode` runs against an
    `openai/...` model.
  - `gemini_api_key` — for the `gemini` runtime and `opencode` runs against a
    `google/...` model.

  Each ciphertext is encrypted with the user's per-tenant DEK
  (see `Fountain.Crypto`). The schema does not store plaintext.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)a

  schema "inference_credentials" do
    field :anthropic_api_key_ciphertext, :binary
    field :claude_code_oauth_token_ciphertext, :binary
    field :openai_api_key_ciphertext, :binary
    field :gemini_api_key_ciphertext, :binary

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "List of supported provider keys (atoms)."
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :user_id,
      :anthropic_api_key_ciphertext,
      :claude_code_oauth_token_ciphertext,
      :openai_api_key_ciphertext,
      :gemini_api_key_ciphertext
    ])
    |> validate_required([:user_id])
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
