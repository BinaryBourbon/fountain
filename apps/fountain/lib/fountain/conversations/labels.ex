defmodule Fountain.Conversations.Labels do
  @moduledoc """
  The rule for a conversation's labels (#1637), in one place.

  A label is a free-form `key => value` pair of strings on the conversation
  row. A person titles and searches their own threads; a program running as a
  teammate wants to slice its runs by facts it knew when the turn ended —
  `env=prod`, `drift=true`, `gated=apply`. Those facts are not text worth
  searching, so they are not in the full-text index and never will be.

  Every door that writes labels goes through `changeset/1` here, called from
  `Fountain.Conversations.Conversation.changeset/2`, so the limits cannot
  drift between one writer and the next:

    * at most 32 entries;
    * a key is a non-empty string of at most 64 bytes;
    * a value is a string of at most 256 bytes;
    * neither may contain a NUL byte, which Postgres refuses inside `jsonb`.

  A refusal names the offending key, because a caller sending thirty-two of
  them cannot otherwise tell which one Fountain disliked.
  """

  import Ecto.Changeset, only: [get_change: 2, add_error: 3]

  @max_entries 32
  @max_key_bytes 64
  @max_value_bytes 256

  @doc "At most this many labels on one conversation."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "A label key is at most this many bytes."
  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @doc "A label value is at most this many bytes."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc """
  Validate the `:labels` change on a conversation changeset.

  Called from `Fountain.Conversations.Conversation.changeset/2`, which is the
  only writer of the column, so every door inherits it. It sees the *merged*
  map, which is the right thing to enforce and the wrong thing to word a
  count refusal from; `Fountain.Conversations._unsafe_merge_labels/3` runs
  `check_merge/2` first for that reason.
  """
  @spec changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def changeset(changeset) do
    case get_change(changeset, :labels) do
      nil -> changeset
      labels -> apply_check(changeset, check(labels))
    end
  end

  defp apply_check(changeset, :ok), do: changeset
  defp apply_check(changeset, {:error, message}), do: add_error(changeset, :labels, message)

  @doc """
  Whether `labels` is a legal label map. `:ok`, or `{:error, message}` naming
  the offending key.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(labels) when is_map(labels) do
    with :ok <- check_entries(labels), do: check_count(labels)
  end

  def check(_labels), do: {:error, "must be an object of string keys and string values"}

  defp check_count(labels) do
    if map_size(labels) > @max_entries do
      # Sorted, so the key named is the same one on every run rather than
      # whichever the map happened to iterate to last.
      over = labels |> Map.keys() |> Enum.sort_by(&describe/1) |> Enum.at(@max_entries)

      {:error, "at most #{@max_entries} labels; #{describe(over)} does not fit"}
    else
      :ok
    end
  end

  defp check_entries(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> describe(key) end)
    |> Enum.reduce_while(:ok, fn {key, value}, _acc ->
      case check_entry(key, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_entry(key, _value) when not is_binary(key),
    do: {:error, "label key #{describe(key)} must be a string"}

  defp check_entry("", _value), do: {:error, "a label key must not be empty"}

  defp check_entry(key, _value) when byte_size(key) > @max_key_bytes,
    do: {:error, "label key #{describe(key)} is longer than #{@max_key_bytes} bytes"}

  defp check_entry(key, value) when not is_binary(value),
    do: {:error, "label #{describe(key)} must have a string value"}

  defp check_entry(key, value) when byte_size(value) > @max_value_bytes,
    do: {:error, "label #{describe(key)} has a value longer than #{@max_value_bytes} bytes"}

  # Postgres refuses a NUL byte inside a jsonb string, so without this clause
  # the write reaches `Repo.update` and comes back as a raised
  # `Postgrex.Error` — a 500 on the HTTP doors, and on the ACP path a raise
  # that would travel up through the turn machine and take the conversation's
  # server down with the turn it was running.
  defp check_entry(key, value) do
    cond do
      nul?(key) -> {:error, "label key #{describe(key)} must not contain a NUL byte"}
      nul?(value) -> {:error, "label #{describe(key)} must not have a NUL byte in its value"}
      true -> :ok
    end
  end

  defp nul?(binary) when is_binary(binary), do: String.contains?(binary, <<0>>)

  # The key, quoted, for a message a caller reads. An over-long key is cut
  # rather than echoed whole: the message identifies which entry to fix, and a
  # 4KB key in an error body helps nobody. Cut by bytes, because bytes are
  # what the limit is measured in — and then backed off to a whole codepoint,
  # since a message sliced through the middle of one is not valid UTF-8 and
  # `Jason.encode!` would raise on it instead of rendering the 422.
  defp describe(key) when is_binary(key) do
    shown =
      if byte_size(key) > @max_key_bytes,
        do: cut(key, @max_key_bytes) <> "...",
        else: key

    ~s("#{shown}")
  end

  defp describe(key), do: inspect(key)

  defp cut(_binary, bytes) when bytes <= 0, do: ""

  defp cut(binary, bytes) do
    candidate = binary_part(binary, 0, bytes)
    if String.valid?(candidate), do: candidate, else: cut(binary, bytes - 1)
  end
end
