defmodule Fountain.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @runtimes ~w(claude codex gemini opencode)

  schema "agents" do
    field :name, :string
    field :description, :string, default: ""
    field :system, :string, default: ""
    field :model, :string
    field :runtime, :string
    # Each entry is one of:
    #   %{"name" => name, "content" => skill_md}     # inline SKILL.md
    #   %{"source" => "owner/repo", "name" => opt}   # github via skills.sh CLI
    field :skills, {:array, :map}, default: []
    field :mcp_servers, :map, default: %{}
    field :metadata, :map, default: %{}
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
      :skills,
      :mcp_servers,
      :metadata,
      :user_id,
      :environment_id
    ])
    |> validate_required([:name, :model, :runtime])
    |> validate_inclusion(:runtime, @runtimes)
    |> validate_format(:model, ~r{^[a-z0-9_-]+/[a-z0-9._-]+$},
      message: "must be in canonical provider/model_id form"
    )
    |> validate_length(:name, min: 1, max: 200)
    |> validate_skills()
    |> unique_constraint(:name)
    |> foreign_key_constraint(:environment_id)
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

    cond do
      has_content and has_source ->
        [skills: "entry #{i}: only one of content or source may be set"]

      not has_content and not has_source ->
        [skills: "entry #{i}: must set content (inline) or source (github)"]

      has_content and not is_binary(name) ->
        [skills: "entry #{i}: inline skills require a name"]

      true ->
        []
    end
  end

  defp skill_errors(_entry, i), do: [skills: "entry #{i}: must be an object"]
end
