defmodule FountainWeb.ChangesetJSON do
  @moduledoc false
  def error(%{changeset: changeset}) do
    %{errors: translate(changeset)}
  end

  defp translate(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
