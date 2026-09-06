defmodule Fountain.ChangesetTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Fountain.Changeset, as: Validators

  defmodule Sample do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "samples" do
      field :one_id, :binary_id
      field :many_ids, {:array, :binary_id}
      field :name, :string
    end
  end

  defp validate(attrs) do
    %Sample{}
    |> cast(attrs, [:one_id, :many_ids, :name])
    |> Validators.validate_ids([:one_id, :many_ids])
  end

  defp message(changeset, field) do
    {message, _opts} = Keyword.fetch!(changeset.errors, field)
    message
  end

  describe "validate_ids/2" do
    test "accepts a uuid" do
      assert validate(%{"one_id" => Ecto.UUID.generate()}).valid?
    end

    test "accepts a list of uuids" do
      ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      assert validate(%{"many_ids" => ids}).valid?
    end

    test "accepts an empty list" do
      assert validate(%{"many_ids" => []}).valid?
    end

    test "leaves a field the caller did not send alone" do
      assert validate(%{"name" => "only a name"}).valid?
    end

    test "refuses a value that is not a uuid, and names it" do
      changeset = validate(%{"one_id" => "toolchain"})

      refute changeset.valid?
      assert message(changeset, :one_id) == ~s(must be an id, but "toolchain" is not one)
    end

    test "refuses a list holding something that is not a uuid, and names it" do
      changeset = validate(%{"many_ids" => [Ecto.UUID.generate(), "prod-creds"]})

      refute changeset.valid?

      assert message(changeset, :many_ids) ==
               ~s(must be a list of ids, but "prod-creds" is not one)
    end

    test "truncates a long value rather than echoing the whole of it" do
      changeset = validate(%{"one_id" => String.duplicate("a", 500)})

      message = message(changeset, :one_id)
      assert message =~ "(truncated)"
      assert String.length(message) < 120
      assert String.valid?(message)
    end

    test "keeps a multi-byte value readable in the message" do
      changeset = validate(%{"one_id" => String.duplicate("é", 500)})

      assert String.valid?(message(changeset, :one_id))
    end

    test "adds nothing where the cast already refused the value" do
      changeset = validate(%{"one_id" => %{"not" => "a string"}})

      refute changeset.valid?
      assert message(changeset, :one_id) == "is invalid"
    end
  end
end
