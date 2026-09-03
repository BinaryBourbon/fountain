defmodule Fountain.Conversations.Output do
  @moduledoc """
  What the sandbox says, on its way to the transcript (#1377).

  Three rules live here: the durable log budget (#331) and the truncation
  marker that says it is spent, the replay skip a reattach needs, and the
  stage events that mark the same stream. `Redaction` is the guard on the
  single writer (`Conversations.log!/1`) and stays where it is; this module
  decides what is written at all, not what a written row may say.

  `from_state/1` reads the three server fields into an `%Output{}` and
  `into_state/2` writes them back; the server's state does not change shape.
  Every function takes what it reads — the conversation, the turn the output
  belongs to and the owner whose sidebar moves, gathered by `ctx/1` — and
  returns the next value. Nothing here holds a process or a timer.
  """

  require Logger

  alias Fountain.Conversations

  @type t :: %__MODULE__{
          bytes: non_neg_integer() | nil,
          capped: boolean(),
          replay_skip: %{String.t() => non_neg_integer()}
        }

  @type ctx :: %{
          conversation_id: String.t(),
          turn_id: String.t() | nil,
          user_id: String.t() | nil
        }

  defstruct bytes: nil, capped: false, replay_skip: %{}

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "What the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state) do
    %__MODULE__{
      bytes: state.output_bytes,
      capped: state.output_capped,
      replay_skip: state.replay_skip
    }
  end

  @doc "The value written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = output) do
    %{
      state
      | output_bytes: output.bytes,
        output_capped: output.capped,
        replay_skip: output.replay_skip
    }
  end

  @doc """
  What a row needs beside the bytes: the conversation, the turn the output
  belongs to, and the owner whose sidebar the broadcast moves.
  """
  @spec ctx(map()) :: ctx()
  def ctx(state) do
    %{
      conversation_id: state.conversation_id,
      turn_id: state.current_turn && state.current_turn.id,
      user_id: state.user_id
    }
  end

  # ── the durable budget (#331) ─────────────────────────────────────────────

  @doc """
  Persist + broadcast one chunk of sandbox output, subject to the
  per-conversation byte budget (#331).

  `log_events` is unbounded per row count and lives on the same Postgres
  volume the app depends on, so a `while true; do base64 /dev/urandom; done`
  sandbox was an availability risk, not just a storage bill — retention
  (#217) bounds age, not rate. Once the budget is exceeded, one truncation
  marker is persisted and every later chunk is dropped. Dropped rather than
  broadcast-only: consumers key ordering off the DB-assigned event id, and an
  unbounded broadcast stream would still let a hostile sandbox saturate
  PubSub.
  """
  @spec log(t(), ctx(), String.t(), binary()) :: t()
  def log(%__MODULE__{} = output, ctx, stream, data) do
    output = ensure_bytes(output, ctx.conversation_id)
    budget = byte_budget()

    cond do
      output.capped ->
        output

      budget > 0 and output.bytes + byte_size(data) > budget ->
        Logger.warning(
          "conv #{ctx.conversation_id}: durable output budget " <>
            "(#{budget} bytes) reached; dropping further sandbox output"
        )

        :telemetry.execute([:fountain, :log_output, :capped], %{count: 1}, %{
          conversation_id: ctx.conversation_id
        })

        persist(ctx, "stderr", cap_marker(budget))
        %{output | capped: true}

      true ->
        persist(ctx, stream, data)
        %{output | bytes: output.bytes + byte_size(data)}
    end
  end

  @doc "The one row that says the budget is spent."
  @spec cap_marker(non_neg_integer()) :: String.t()
  def cap_marker(budget) do
    "\n[fountain] This conversation reached its durable log budget of " <>
      "#{div(budget, 1_000_000)} MB. Further sandbox output is discarded — " <>
      "the turn keeps running, and stage events still appear.\n"
  end

  @doc """
  Load the conversation's byte total on the first output of a server's
  lifetime, so the budget is cumulative across wakes rather than per BEAM
  lifetime.
  """
  @spec ensure_bytes(t(), String.t()) :: t()
  def ensure_bytes(%__MODULE__{bytes: nil} = output, conversation_id) do
    # ownership: a server's own conversation, established at init.
    %{output | bytes: Conversations._unsafe_output_byte_total(conversation_id)}
  end

  def ensure_bytes(%__MODULE__{} = output, _conversation_id), do: output

  @doc "The budget in bytes. 0 disables the cap."
  @spec byte_budget() :: non_neg_integer()
  def byte_budget do
    Application.get_env(:fountain, :log_output_byte_budget, 50_000_000)
  end

  @doc """
  Write one chunk to the transcript and broadcast it, with no budget
  arithmetic: what `log/4` does once it has decided the chunk is affordable.
  """
  @spec persist(ctx(), String.t(), binary()) :: :ok
  def persist(ctx, stream, data) do
    # Tag this output with the stage that's active right now. The
    # runtime CLI is always spawned inside a `turn` so all stdout /
    # stderr from it gets `stage: "turn"`. Any operator on the
    # presentation side (LiveView grouping, SSE consumers) can group
    # output by stage without inferring it from event interleaving.
    event =
      Conversations.log!(%{
        conversation_id: ctx.conversation_id,
        turn_id: ctx.turn_id,
        kind: "output",
        stream: stream,
        stage: "turn",
        data: data
      })

    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "conv:#{ctx.conversation_id}",
      {:log_event, event}
    )

    if ctx.user_id do
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        "sidebar:#{ctx.user_id}",
        {:sidebar_update, ctx.user_id}
      )
    end

    :ok
  end

  # ── the reattach replay skip ──────────────────────────────────────────────

  @doc """
  Drop replayed bytes before persisting.

  After reattach, sprites replays the session's buffered output up to where
  it left off, then live-tails. We pre-loaded the byte count we'd already
  persisted for the in-flight turn into `replay_skip[stream]`; consume that
  many bytes off the front of incoming data, then start logging the remainder
  normally.
  """
  @spec log_with_replay_skip(t(), ctx(), String.t(), binary()) :: t()
  def log_with_replay_skip(%__MODULE__{} = output, ctx, stream, data) do
    skip = Map.get(output.replay_skip, stream, 0)
    size = byte_size(data)

    cond do
      skip == 0 ->
        log(output, ctx, stream, data)

      skip >= size ->
        put_in(output.replay_skip[stream], skip - size)

      true ->
        output = log(output, ctx, stream, binary_part(data, skip, size - skip))
        put_in(output.replay_skip[stream], 0)
    end
  end

  # ── stage events ──────────────────────────────────────────────────────────

  @doc """
  The transcript's other half: a lifecycle marker on the same stream the
  chunks go to. Unbudgeted — a stage event is one row per transition, and
  losing them is how a client stops being able to tell a stuck agent from a
  finished one.
  """
  @spec publish_stage(String.t(), String.t(), String.t(), map()) :: Conversations.LogEvent.t()
  def publish_stage(conv_id, stage, status, meta \\ %{}) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end

  # ── images into the sandbox ───────────────────────────────────────────────

  @doc """
  Write each image to a temp path in the sprite filesystem and return a list
  of `{path, media_type}` tuples for passing to the runtime.
  """
  @spec write_image_temp_files(term(), String.t(), list()) :: [{String.t(), String.t()}]
  def write_image_temp_files(_handle, _turn_id, []), do: []

  def write_image_temp_files(handle, turn_id, images) do
    images
    |> Enum.with_index()
    |> Enum.map(fn {%{media_type: mt, data: data}, idx} ->
      ext = media_type_to_ext(mt)
      path = "/tmp/aod_turn_#{turn_id}_#{idx}.#{ext}"
      Managoat.Sandbox.write_file(handle, path, data)
      {path, mt}
    end)
  end

  defp media_type_to_ext("image/png"), do: "png"
  defp media_type_to_ext("image/jpeg"), do: "jpeg"
  defp media_type_to_ext("image/gif"), do: "gif"
  defp media_type_to_ext("image/webp"), do: "webp"
  defp media_type_to_ext(_), do: "bin"
end
