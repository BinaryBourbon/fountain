defmodule Fountain.Environments.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Environments.Secret

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @networking ~w(unrestricted limited)

  # Fields that affect provisioning. Changing any of these invalidates
  # the env's sprite checkpoint — the warm-start state would be wrong.
  @warm_start_fields [
    :packages,
    :env_vars,
    :setup_script,
    :networking_type,
    :networking_config,
    :repositories
  ]

  schema "environments" do
    field :name, :string
    field :packages, :map, default: %{}
    field :env_vars, :map, default: %{}
    field :setup_script, :string, default: ""
    field :networking_type, :string, default: "unrestricted"
    field :networking_config, :map, default: %{}
    field :repositories, {:array, :map}, default: []
    field :checkpoint_id, :string
    has_many :secrets, Secret
    timestamps(type: :utc_datetime)
  end

  def warm_start_fields, do: @warm_start_fields

  def changeset(env, attrs) do
    env
    |> cast(attrs, [
      :name,
      :packages,
      :env_vars,
      :setup_script,
      :networking_type,
      :networking_config,
      :repositories,
      :checkpoint_id
    ])
    |> validate_required([:name])
    |> validate_inclusion(:networking_type, @networking)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_change(:repositories, &validate_repositories/2)
    |> maybe_invalidate_checkpoint()
    |> unique_constraint(:name)
  end

  # If any provisioning-relevant field changed AND the caller didn't
  # explicitly set checkpoint_id in this changeset, drop the existing
  # checkpoint — the warm-start state would diverge from the env's
  # actual config. The next provision will create a fresh checkpoint.
  defp maybe_invalidate_checkpoint(changeset) do
    explicitly_set? = Map.has_key?(changeset.changes, :checkpoint_id)

    changed_warm? =
      Enum.any?(@warm_start_fields, fn f -> Map.has_key?(changeset.changes, f) end)

    if changed_warm? and not explicitly_set? do
      put_change(changeset, :checkpoint_id, nil)
    else
      changeset
    end
  end

  defp validate_repositories(_field, list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"url" => url, "mount_path" => mount}
      when is_binary(url) and is_binary(mount) and url != "" and mount != "" ->
        if String.starts_with?(mount, "/") and String.starts_with?(url, "https://") do
          []
        else
          [repositories: "url must be https:// and mount_path must be absolute"]
        end

      _ ->
        [repositories: "each entry needs `url` (https://...) and `mount_path` (/abs/path)"]
    end)
  end

  defp validate_repositories(_, _), do: []
end
