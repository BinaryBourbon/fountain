defmodule FountainWeb.ChangesetJSONTest do
  use Fountain.DataCase, async: true

  alias FountainWeb.ChangesetJSON

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a throwaway schemaless changeset using the given types and attrs, then
  # apply the supplied validator function (if any).
  defp build_changeset(types, attrs, validator \\ & &1) do
    {%{}, types}
    |> Ecto.Changeset.cast(attrs, Map.keys(types))
    |> validator.()
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "error/1" do
    test "returns empty errors map when changeset has no errors" do
      cs = build_changeset(%{name: :string}, %{name: "Alice"})
      assert ChangesetJSON.error(%{changeset: cs}) == %{errors: %{}}
    end

    test "includes field key with message for a required-field error" do
      cs =
        build_changeset(%{email: :string}, %{}, fn cs ->
          Ecto.Changeset.validate_required(cs, [:email])
        end)

      %{errors: errors} = ChangesetJSON.error(%{changeset: cs})
      assert Map.has_key?(errors, :email)
      assert "can't be blank" in errors.email
    end

    test "interpolates %{count} placeholders from validate_length" do
      cs =
        build_changeset(%{username: :string}, %{username: "ab"}, fn cs ->
          Ecto.Changeset.validate_length(cs, :username, min: 5)
        end)

      %{errors: errors} = ChangesetJSON.error(%{changeset: cs})
      assert Map.has_key?(errors, :username)
      # The rendered message must contain the interpolated count ("5"), not the
      # raw placeholder "%{count}".
      message = errors.username |> List.first()
      assert message =~ "5"
      refute message =~ "%{count}"
    end

    test "includes all fields when multiple fields have errors" do
      cs =
        build_changeset(%{first_name: :string, last_name: :string}, %{}, fn cs ->
          Ecto.Changeset.validate_required(cs, [:first_name, :last_name])
        end)

      %{errors: errors} = ChangesetJSON.error(%{changeset: cs})
      assert Map.has_key?(errors, :first_name)
      assert Map.has_key?(errors, :last_name)
    end
  end
end
