defmodule Fountain.Workers.DetachedRequestSweeper do
  @moduledoc """
  Denies permission requests that outlived their turn and then ran out of
  time (#1635).

  A request held inside a running turn is timed by a process timer in the
  `ConversationServer`. A detached one cannot be: the whole point of it is
  that the sandbox parks and the server stops while the request waits, and a
  deploy in the middle of a two-day wait would drop the timer with nothing to
  notice. So the deadline lives on the turn row (`turns.permission_deadline`,
  with a partial index over `waiting`) and this sweep is what reads it.

  Expiry is a denial, which is the only safe default, and the denial reaches
  the agent the same way an answer does: the request is resolved on the row
  and a new turn is opened carrying the outcome, waking the sandbox. The
  option it names is one the agent itself offered.

  The grain is a minute. A detached deadline is hours or days, so a minute of
  overshoot is immaterial, and the query is one indexed read that is empty
  almost every time. The batch is capped so a backlog cannot wake a hundred
  sandboxes at once.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.Turn
  alias Fountain.Repo

  @sweep_limit 25

  @impl Oban.Worker
  def perform(_job) do
    expired = sweep_expired_requests()

    if expired > 0, do: Logger.info("detached_request_sweeper: expired=#{expired}")

    :telemetry.execute([:fountain, :detached_request_sweeper, :run], %{expired: expired}, %{})

    :ok
  end

  @doc false
  def sweep_expired_requests(now \\ DateTime.utc_now()) do
    Turn
    |> where([t], t.waiting == true and not is_nil(t.pending_permission))
    |> where([t], t.permission_deadline <= ^now)
    |> order_by([t], asc: t.permission_deadline)
    |> limit(^@sweep_limit)
    |> Repo.all()
    |> Enum.count(&expire/1)
  end

  # Ownership: a system sweep, which ADR 0013 and the `_unsafe_` rules name as
  # a legitimate caller. The resolution is guarded on the request id, so a
  # client answering in the same second wins or loses cleanly rather than
  # both landing.
  defp expire(%Turn{} = turn) do
    case Conversations._unsafe_expire_detached_request(turn) do
      :ok ->
        Logger.info(
          "detached_request_sweeper: denied request on turn #{turn.id} " <>
            "(conversation #{turn.conversation_id}) after its deadline"
        )

        true

      {:error, :no_pending_permission} ->
        false

      {:error, reason} ->
        Logger.warning(
          "detached_request_sweeper: could not resume conversation " <>
            "#{turn.conversation_id} after denying its request: #{inspect(reason)}"
        )

        # The request itself is resolved either way; only the resume turn
        # failed to open, and that is what the log line is for.
        true
    end
  end
end
