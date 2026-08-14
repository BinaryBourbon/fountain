defmodule Fountain.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Environments.Environment
  alias Fountain.Runtimes.Model

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @runtimes ~w(claude codex gemini opencode)

  @typedoc "A persisted agent."
  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :description, :string, default: ""
    field :system, :string, default: ""
    field :model, :string
    field :runtime, :string
    # Optional sandbox-backend override; nil inherits the instance default
    # (SANDBOX_PROVIDER) at conversation start.
    field :sandbox_provider, :string
    # Each entry is one of:
    #   %{"name" => name, "content" => skill_md}     # inline SKILL.md
    #   %{"source" => "owner/repo", "name" => opt}   # github via skills.sh CLI
    field :skills, {:array, :map}, default: []
    field :mcp_servers, :map, default: %{}
    field :metadata, :map, default: %{}
    # Vaults a conversation may attach to this agent. nil = any tenant
    # vault (legacy), [] = none, non-empty = allowlist. Vault values win
    # on env-var collision, so an attached vault can override reviewed
    # agent config — this is the lever that scopes who can do that.
    field :allowed_vault_ids, {:array, :binary_id}
    field :avatar_media_type, :string
    field :conversation_count, :integer, virtual: true, default: 0
    belongs_to :user, User
    belongs_to :environment, Environment
    timestamps(type: :utc_datetime)
  end

  def runtimes, do: @runtimes

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :description,
      :system,
      :model,
      :runtime,
      :sandbox_provider,
      :skills,
      :mcp_servers,
      :metadata,
      :allowed_vault_ids,
      :user_id,
      :environment_id
    ])
    |> validate_required([:name, :model, :runtime])
    |> validate_inclusion(:runtime, @runtimes)
    |> validate_format(:model, ~r{^[a-z0-9_-]+/[a-z0-9._-]+$},
      message: "must be in canonical provider/model_id form"
    )
    |> validate_model_provider()
    |> validate_sandbox_provider()
    |> validate_length(:name, min: 1, max: 200)
    |> validate_skills()
    |> unique_constraint(:name, name: :agents_user_id_name_index)
    |> foreign_key_constraint(:environment_id)
  end

  # claude / codex / gemini each drive a single provider's CLI and take a
  # bare model id, so the runtime strips the canonical prefix at spawn.
  # Reject a mismatched prefix here rather than shipping `gpt-5` to
  # `claude --model`: before #553 those runtimes ignored the field
  # entirely, so `openai/gpt-5` on a claude agent looked configured and
  # silently ran the CLI's own default.
  #
  # opencode takes any *known* prefix. It is multi-provider but not
  # open-ended: it reads the prefix to pick which API key to export, and
  # Fountain only holds three (`InferenceCredentials.Credential`). A
  # misspelled provider used to fall through to no credentials at all and
  # fail as an auth error inside the sprite, so reject it here too (#554).
  #
  # The model id itself is never checked — a model released since the last
  # deploy has to work the day it ships.
  defp validate_model_provider(changeset) do
    case Model.provider(get_field(changeset, :model)) do
      nil -> changeset
      actual -> validate_provider(changeset, actual, get_field(changeset, :runtime))
    end
  end

  defp validate_provider(changeset, actual, runtime) do
    case Model.provider_for_runtime(runtime) do
      nil -> validate_known_provider(changeset, actual)
      ^actual -> changeset
      expected -> add_error(changeset, :model, "#{runtime} runtime requires a #{expected}/ model")
    end
  end

  defp validate_known_provider(changeset, provider) do
    if Model.known_provider?(provider) do
      changeset
    else
      add_error(
        changeset,
        :model,
        "unknown provider \"#{provider}\" — must be one of: #{Enum.join(Model.providers(), ", ")}"
      )
    end
  end

  # Distinct from the *model* provider above: this picks which sandbox
  # backend the agent's conversations run on. Nil inherits the instance
  # default. Only validated when the field changes, so removing a provider's
  # credentials later does not brick unrelated edits to existing agents —
  # conversation start re-checks enabledness anyway.
  defp validate_sandbox_provider(changeset) do
    validate_change(changeset, :sandbox_provider, fn :sandbox_provider, value ->
      cond do
        value not in Fountain.Sandbox.known_providers() ->
          [
            sandbox_provider:
              "must be one of: " <> Enum.join(Fountain.Sandbox.known_providers(), ", ")
          ]

        not Fountain.Sandbox.enabled?(String.to_existing_atom(value)) ->
          [sandbox_provider: "is not configured on this instance"]

        true ->
          []
      end
    end)
  end

  defp validate_skills(changeset) do
    validate_change(changeset, :skills, fn :skills, skills ->
      skills
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, i} -> skill_errors(entry, i) end)
    end)
  end

  defp skill_errors(entry, i) when is_map(entry) do
    has_content = is_binary(Map.get(entry, "content") || Map.get(entry, :content))
    has_source = is_binary(Map.get(entry, "source") || Map.get(entry, :source))
    name = Map.get(entry, "name") || Map.get(entry, :name)
    ref = Map.get(entry, "ref") || Map.get(entry, :ref)

    cond do
      has_content and has_source ->
        [skills: "entry #{i}: only one of content or source may be set"]

      not has_content and not has_source ->
        [skills: "entry #{i}: must set content (inline) or source (github)"]

      has_content and not is_binary(name) ->
        [skills: "entry #{i}: inline skills require a name"]

      has_content and not is_nil(ref) ->
        [skills: "entry #{i}: ref only applies to github-sourced skills"]

      not is_nil(ref) and not valid_ref?(ref) ->
        [skills: "entry #{i}: ref must match [A-Za-z0-9._/-]+ (tag, branch, or sha)"]

      true ->
        []
    end
  end

  defp skill_errors(_entry, i), do: [skills: "entry #{i}: must be an object"]

  # Mirrors SpriteSkills.safe_token!/1 — the ref is interpolated into the
  # sprite-side install command, so reject anything outside the allow-list
  # at write time instead of failing the spawn later.
  defp valid_ref?(ref) when is_binary(ref), do: Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, ref)
  defp valid_ref?(_), do: false
end
