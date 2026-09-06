defmodule Fountain.Conversations.Labels do
  @moduledoc """
  The rule for a conversation's labels (#1637), in one place.

  A label is a free-form `key => value` pair of strings on the conversation
  row. A person titles and searches their own threads; a program running as a
  teammate wants to slice its runs by facts it knew when the turn ended —
  `env=prod`, `drift=true`, `gated=apply`. Those facts are not text worth
  searching, so they are not in the full-text index and never will be.

  Every door that writes labels goes through `changeset/1` here, so the
  limits cannot drift between the create request, the labels route, the team
  message and the ACP extension notification:

    * at most 32 entries;
    * a key is a non-empty string of at most 64 bytes;
    * a value is a string of at most 256 bytes.

  A refusal names the offending key, because a caller sending thirty-two of
  them cannot otherwise tell which one Fountain disliked.

  ## Merge, and how a key is removed

  Writes merge (`merge/2`): a key that is not mentioned is left alone. A key
  whose value is `null` is removed. That is what lets a run add one label
  without reading the others first, and what makes a channel resume keep the
  labels the binding already carried.

  ## The list filter

  `GET /api/conversations?label=env:prod&label=drift:true` is repeatable and
  AND-combined. Each value splits on its **first** colon only, so
  `label=path:a:b` filters `path` for `a:b`. The query is jsonb containment,
  which the GIN index on the column serves.
  """

  import Ecto.Changeset, only: [get_change: 2, add_error: 3]

  require Logger

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
  only writer of the column, so every door inherits it.
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
    with :ok <- check_count(labels), do: check_entries(labels)
  end

  def check(_labels), do: {:error, "must be an object of string keys and string values"}

  defp check_count(labels) do
    if map_size(labels) > @max_entries do
      # Sorted, so the key named is the same one on every run rather than
      # whichever the map happened to iterate to last.
      over = labels |> Map.keys() |> Enum.map(&describe/1) |> Enum.sort() |> Enum.at(@max_entries)

      {:error, "at most #{@max_entries} labels; #{over} is over the limit"}
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

  defp check_entry(_key, _value), do: :ok

  # The key, quoted, for a message a caller reads. An over-long key is cut
  # rather than echoed whole: the message identifies which entry to fix, and a
  # 4KB key in an error body helps nobody.
  defp describe(key) when is_binary(key) do
    shown =
      if byte_size(key) > @max_key_bytes,
        do: String.slice(key, 0, @max_key_bytes) <> "...",
        else: key

    ~s("#{shown}")
  end

  defp describe(key), do: inspect(key)

  @doc """
  Merge `incoming` into `current`. A key with a `nil` value is removed; a key
  that is absent is left alone.

  Nothing is validated here — the merged map goes through `changeset/1` on
  its way to the row, so a write that would break a limit is refused with the
  key named rather than half-applied.
  """
  @spec merge(map() | nil, map()) :: map()
  def merge(current, incoming) when is_map(incoming) do
    Enum.reduce(incoming, current || %{}, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  @doc """
  Which keys `merge/2` would change, as `{written, removed}` — both sorted,
  both keys only.

  The audit trail records these and never the values (ADR 0013).
  """
  @spec changed_keys(map() | nil, map()) :: {[String.t()], [String.t()]}
  def changed_keys(current, incoming) when is_map(incoming) do
    current = current || %{}

    {removed, written} =
      incoming
      |> Enum.filter(fn {key, value} -> Map.get(current, key, :absent) != value end)
      |> Enum.split_with(fn {_key, value} -> is_nil(value) end)

    {written |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort(),
     removed
     |> Enum.map(&to_string(elem(&1, 0)))
     |> Enum.filter(&Map.has_key?(current, &1))
     |> Enum.sort()}
  end

  @doc """
  Merge the labels an agent stamped on its own run over the ACP extension
  notification (#1637).

  Ownership is the caller's: only the turn machine of the conversation's own
  server reaches this, and it holds that conversation's id. Recorded as
  `sprite` — code in the sandbox acting on the tenant's behalf (ADR 0013).

  A stamp the limits refuse is logged and dropped. The run is mid-turn and
  doing real work, and losing the turn because a value was 300 bytes long
  would be the worse outcome.
  """
  @spec stamp(String.t() | nil, map()) :: :ok
  def stamp(conversation_id, labels)

  def stamp(conversation_id, labels) when is_binary(conversation_id) and is_map(labels) do
    # ownership: the ConversationServer established it at start, and the id
    # here is the one its own turn machine holds. No request reaches this.
    with %{} = conv <- Fountain.Conversations._unsafe_get_conversation(conversation_id),
         {:error, changeset} <- Fountain.Conversations.merge_labels(conv, labels, actor: "sprite") do
      Logger.warning(
        "conv #{conversation_id}: refused _fountain/labels update: #{inspect(changeset.errors)}"
      )
    end

    :ok
  end

  def stamp(_conversation_id, _labels), do: :ok

  @doc """
  Every `label` value in a raw query string, in the order they were sent.

  Read from the query string rather than from the parsed params because Plug
  collapses a repeated key to its last value, and the filter is repeatable by
  design. `label[]=` is accepted as well, for a client whose HTTP layer only
  builds arrays that way.
  """
  @spec from_query_string(String.t() | nil) :: [String.t()]
  def from_query_string(nil), do: []

  def from_query_string(query) when is_binary(query) do
    for {key, value} <- URI.query_decoder(query), key in ["label", "label[]"], do: value
  end

  @doc """
  Turn repeated `key:value` filter values into the map the list query
  contains against. Splits on the first colon only, so a value may contain
  colons of its own.

  `{:error, :invalid_label_filter}` for a value with no colon or an empty
  key: a caller who typed `?label=prod` meant something, and matching
  everything would be the wrong guess.
  """
  @spec parse_filter([String.t()] | nil) :: {:ok, map()} | {:error, :invalid_label_filter}
  def parse_filter(nil), do: {:ok, %{}}

  def parse_filter(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      case value |> to_string() |> String.trim() |> String.split(":", parts: 2) do
        ["" | _] -> {:halt, {:error, :invalid_label_filter}}
        [key, filter_value] -> {:cont, {:ok, Map.put(acc, key, filter_value)}}
        [_no_colon] -> {:halt, {:error, :invalid_label_filter}}
      end
    end)
  end

  def parse_filter(value) when is_binary(value), do: parse_filter([value])
end
