defmodule Fountain.Activation do
  @moduledoc """
  Activation is **the first conversation with a reply** (ADR 0038).

  One definition, in one module, for the two readers that ask about it:

    * `Fountain.Funnel`, which counts accounts and measures verification to
      first reply, and
    * PostHog, which gets `activation.first_reply` the moment it happens so a
      funnel can put the landing page's own events either side of it.

  A reply is a `turns` row whose `reply_text` is a non-empty string.
  `Conversations._unsafe_update_turn/2` materialises that column from the
  turn's events when the turn ends, through the same parse the transcript
  uses (`Conversations.Blocks.assistant_text/2`, which trims and returns `""`
  when the agent said nothing), so "the agent answered" needs no second
  definition here. A conversation that provisioned a sandbox, ran, and
  produced no assistant text is not an activation.

  ## The seam

  `turn_replied/1` is called from `Conversations._unsafe_update_turn/2` —
  every turn ending in the system goes through there, from the
  ConversationServer's six endings to the orphan sweep, so a new way for a
  turn to end is instrumented by construction rather than by remembering.
  It is the *account's first* reply that this module cares about, so the
  function is a no-op for every later turn.

  **#1390 stamps `users.onboarding_completed_at` here**, at the first reply,
  instead of the dashboard checklist stamping it when three things exist.
  The call site is marked in `capture_first_reply/2`; the field is untouched
  by this module today.

  ## What it costs

  Two queries per turn that ends with a reply — the conversation's owner, and
  whether an earlier reply already exists for that owner — and a third (the
  user row, for the time since verification) only on the one turn per account
  that is the first. It is best-effort: a raise here would take a turn ending
  with it, so everything is rescued, exactly as
  `Conversations.publish_stage/4` treats its own analytics mirror.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Conversations.{Conversation, Turn}
  alias Fountain.Repo

  @event "activation.first_reply"

  @doc """
  The moment each account first got a reply: `%{user_id => DateTime.t()}`.

  The turn's `ended_at`, which is when the reply landed; a turn that ended
  without one stamped falls back to when its row was written, so a missing
  timestamp cannot silently drop an activated account out of the funnel.
  No tenant scope — the caller is the admin funnel.
  """
  @spec first_reply_by_user() :: %{String.t() => DateTime.t()}
  def first_reply_by_user do
    # The reply predicate, repeated in the two queries below it: non-null and
    # non-empty. `assistant_text/2` trims and yields "" for "the agent said
    # nothing", which `_unsafe_turn_reply_text/1` turns into nil — the
    # empty-string arm is belt and braces for rows written any other way,
    # including the #826 backfill.
    Repo.all(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: not is_nil(t.reply_text) and t.reply_text != "",
        group_by: c.user_id,
        select: {c.user_id, type(min(coalesce(t.ended_at, t.inserted_at)), :utc_datetime)}
    )
    |> Map.new()
  end

  @doc """
  When `user_id` first got a reply, or `nil` if it never has.
  """
  @spec first_reply_at(String.t()) :: DateTime.t() | nil
  def first_reply_at(user_id) when is_binary(user_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.user_id == ^user_id,
        where: not is_nil(t.reply_text) and t.reply_text != "",
        select: type(min(coalesce(t.ended_at, t.inserted_at)), :utc_datetime)
    )
  end

  @doc """
  A turn has ended carrying a reply: if it is the account's first, this is
  activation.

  Returns `:ok` in every case, including when the turn has no reply, when the
  account activated long ago, and when anything at all goes wrong. Callers
  are on the turn-ending path and must never branch on it.
  """
  @spec turn_replied(Turn.t()) :: :ok
  def turn_replied(%Turn{reply_text: text} = turn) when is_binary(text) and text != "" do
    with user_id when is_binary(user_id) <- owner_of(turn),
         true <- first_reply?(user_id, turn) do
      capture_first_reply(user_id, turn)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("activation: first-reply check failed: #{inspect(e)}")
      :ok
  end

  def turn_replied(_turn), do: :ok

  @doc """
  The PostHog event name this module emits, and the names the verified
  landing (#1390) emits either side of it.

  The funnel ADR 0038 asks for is `auth.email.verified` →
  `onboarding.landing_viewed` → `onboarding.request_sent` →
  `activation.first_reply`. The first arrives already, from the audit trail's
  own choke point (`Accounts.verify_email/2` records `auth.email.verified`);
  the last is emitted here; the middle two are the landing page's, and are
  named here so the funnel definition and the page that fills it cannot drift
  apart. `onboarding.key_copied` is the fourth moment #1390 captures and is
  not a funnel step: copying is not doing.
  """
  @spec funnel_events() :: [String.t()]
  def funnel_events do
    [
      "auth.email.verified",
      "onboarding.landing_viewed",
      "onboarding.request_sent",
      @event
    ]
  end

  defp owner_of(%Turn{} = turn) do
    Repo.one(
      from c in Conversation,
        join: t in Turn,
        on: t.conversation_id == c.id,
        where: t.id == ^turn.id,
        select: c.user_id
    )
  end

  # Is `turn` the earliest replied turn this account has? Ordered by the same
  # timestamp `first_reply_by_user/0` reports, with the id as the tie-break so
  # two turns that ended in the same second still name one winner.
  defp first_reply?(user_id, %Turn{} = turn) do
    earliest =
      Repo.one(
        from t in Turn,
          join: c in Conversation,
          on: c.id == t.conversation_id,
          where: c.user_id == ^user_id,
          where: not is_nil(t.reply_text) and t.reply_text != "",
          order_by: [asc: coalesce(t.ended_at, t.inserted_at), asc: t.id],
          limit: 1,
          select: t.id
      )

    earliest == turn.id
  end

  defp capture_first_reply(user_id, %Turn{} = turn) do
    # #1390: stamp `users.onboarding_completed_at` here, on this branch —
    # it runs exactly once per account, at the first reply, whatever door the
    # request came through. Nothing writes it from this module today.
    user = Repo.get(User, user_id)
    at = turn.ended_at || turn.inserted_at

    Fountain.Analytics.capture(
      @event,
      user_id,
      %{
        "conversation_id" => turn.conversation_id,
        "turn_id" => turn.id,
        "turn_number" => turn.turn_number,
        "origin" => turn.origin,
        "hours_since_verified" => hours_since_verified(user, at),
        "source" => "activation"
      },
      timestamp: at,
      set_once: %{"first_reply_at" => iso(at)}
    )
  end

  defp hours_since_verified(%User{email_verified_at: %DateTime{} = verified_at}, %DateTime{} = at) do
    Float.round(DateTime.diff(at, verified_at, :second) / 3600, 3)
  end

  defp hours_since_verified(_user, _at), do: nil

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil
end
