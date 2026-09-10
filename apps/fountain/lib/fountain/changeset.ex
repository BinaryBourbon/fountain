defmodule Fountain.Changeset do
  @moduledoc """
  Validations shared by more than one schema.

  ## Why `validate_ids/2` exists

  `:binary_id` accepts anything a caller sends. `Ecto.Type.cast/2` on the
  primitive takes any string, and only the adapter's *dump* rejects a value
  that is not a uuid — by raising `Ecto.ChangeError` from inside
  `Repo.insert/1`, after `changeset.valid?` has already said true. A caller
  who sends a vault's name where its id belongs therefore got a bare 500 and
  a dropped connection instead of a 422 naming the field (#1679), while every
  other bad value in the same request produced a clean validation error.

  So an id field a caller can name is validated here, next to the rules that
  already run on the same changeset, rather than being left to the database
  layer.
  """

  import Ecto.Changeset

  # Long enough to recognise what was sent, short enough that the error body
  # cannot be used to echo a payload back. Cuts by character, so the message
  # is always valid UTF-8.
  @echo_limit 40

  @doc """
  Refuse a value that is not a uuid in each of `fields`.

  Handles a single id and a list of them. A field the changeset did not
  change is not visited, and neither is one that already failed to cast, so
  this adds an error only where a caller supplied something the database
  would have raised on.
  """
  @spec validate_ids(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate_ids(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value -> id_errors(field, value) end)
    end)
  end

  defp id_errors(field, values) when is_list(values) do
    case Enum.reject(values, &uuid?/1) do
      [] -> []
      [bad | _] -> [{field, "must be a list of ids, but #{describe(bad)} is not one"}]
    end
  end

  defp id_errors(field, value) do
    if uuid?(value), do: [], else: [{field, "must be an id, but #{describe(value)} is not one"}]
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.dump(value))
  defp uuid?(_value), do: false

  defp describe(value) when is_binary(value) do
    cut = String.slice(value, 0, @echo_limit)
    if cut == value, do: inspect(cut), else: inspect(cut) <> " (truncated)"
  end

  defp describe(value), do: inspect(value, limit: 3, printable_limit: @echo_limit)
end
