defmodule Fountain.Conversations.Redaction do
  @moduledoc """
  Redacts tenant secrets out of sprite output before it is persisted.

  Decrypted secrets are placed in the sprite's environment and written to
  `/home/sprite/.env`, and every byte a sprite writes to stdout or stderr is
  persisted verbatim into `log_events` and streamed over SSE. So an `env`, a
  `set -x`, a `cat .env` in someone's `setup_script`, or an agent that simply
  prints its environment, wrote plaintext credentials into Postgres — a table
  with none of the envelope encryption the secret itself has, and one that
  outlives the conversation.

  ## Why a registry rather than an argument

  A scrubber already existed for git's HTTPS token, and it was applied on the
  HTTPS clone path and *not* on the SSH one. That is the failure mode worth
  designing against: redaction that a caller has to remember will eventually be
  forgotten by a new caller.

  So the values live in an ETS table keyed by conversation, and
  `Conversations.log!/1` — the single writer for every log event — consults it.
  A new log path is redacted whether or not its author knew this module existed.

  ## The length floor

  Only values of at least #{8} bytes are redacted. Sprite environments hold
  plenty of short non-secrets (`true`, `1`, a port, a region), and redacting
  those would turn logs into noise while protecting nothing. Real credentials —
  tokens, keys, connection strings — are comfortably longer. A deliberately
  short password is the case this misses, and is worth knowing about.
  """

  use GenServer

  @table :fountain_redaction
  @min_length 8
  @placeholder "[REDACTED]"

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc """
  Register the values to redact for a conversation.

  Accepts the sprite env as a keyword-ish list of `{name, value}` tuples, or a
  plain list of values.
  """
  def put(conversation_id, values) when is_binary(conversation_id) and is_list(values) do
    redactable =
      values
      |> Enum.map(fn
        {_name, value} -> value
        value -> value
      end)
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_length))
      # Longest first: a secret that contains another as a substring must be
      # replaced whole, or the shorter match would leave a fragment behind.
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.uniq()

    if redactable == [] do
      delete(conversation_id)
    else
      ensure_table()
      :ets.insert(@table, {conversation_id, redactable})
    end

    :ok
  end

  def put(_conversation_id, _values), do: :ok

  @doc "Forget a conversation's values. Called when its server stops."
  def delete(conversation_id) when is_binary(conversation_id) do
    ensure_table()
    :ets.delete(@table, conversation_id)
    :ok
  end

  def delete(_), do: :ok

  @doc """
  Replace any registered secret value appearing in `text`.

  Returns `text` unchanged when the conversation has no registered values, which
  is the common case for conversations with no secrets at all.
  """
  def redact(conversation_id, text) when is_binary(conversation_id) and is_binary(text) do
    case lookup(conversation_id) do
      [] -> text
      values -> :binary.replace(text, values, @placeholder, [:global])
    end
  end

  def redact(_conversation_id, text), do: text

  @doc "Values registered for a conversation. Empty when none or unavailable."
  def lookup(conversation_id) when is_binary(conversation_id) do
    ensure_table()

    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, values}] -> values
      _ -> []
    end
  catch
    :error, :badarg -> []
  end

  def lookup(_), do: []

  def min_length, do: @min_length
  def placeholder, do: @placeholder

  # The table is owned by this GenServer. Tests and any caller that runs before
  # the supervision tree is up should degrade to "no redaction registered"
  # rather than crash the operation being logged.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  A `ConversationServer` state with every secret in it replaced, for
  `format_status/1` (#315).

  An unhandled raise in any callback logs `State:` through `inspect`. Without
  this that meant plaintext env secrets, the raw tenant DEK, decrypted BYO
  inference credentials, the callback API key and the platform Sprites token
  (inside `sprite.client`) on stdout and, with `SENTRY_DSN` set, in a Sentry
  event body. Sentry's PlugContext scrubbing never sees process crash reports,
  so the redaction has to happen at the server.

  Key names are kept and only values are replaced, so crash reports stay
  debuggable.
  """
  def server_state(state) do
    %{
      state
      | handle: state.handle && %{state.handle | private: nil},
        sprite_env: Enum.map(state.sprite_env, fn {k, _v} -> {k, "[REDACTED]"} end),
        tenant_key: secret(state.tenant_key),
        inference_credentials: secrets(state.inference_credentials),
        callback_token: secret(state.callback_token)
    }
  end

  @doc false
  def server_status(status) do
    Map.new(status, fn
      {:state, %{conversation_id: _} = state} -> {:state, server_state(state)}
      other -> other
    end)
  end

  defp secrets(%{} = map), do: Map.new(map, fn {k, _v} -> {k, "[REDACTED]"} end)
  defp secrets(other), do: secret(other)

  defp secret(nil), do: nil
  defp secret(_present), do: "[REDACTED]"
end
