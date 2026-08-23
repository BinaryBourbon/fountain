defmodule FountainWeb.Plugs.AnalyticsIdentity do
  @moduledoc """
  Joins the anonymous visitor to the account, the moment a session begins.

  A person reads the landing page, opens the manual, and signs up. posthog-js
  recorded the first two under a generated anonymous id
  (`FountainWeb.Plugs.WebAnalytics`); the server records everything after
  under `user.id`. Without something in between they are two people, the
  acquisition funnel has no top, and "where did the accounts that converted
  come from" has no answer — which was the state of the project before this.

  ## Why a plug, and not five call sites

  A browser session is established in five places today — password login,
  HTML registration, the OAuth callback (for both a new signup and a returning
  user), email verification, and the re-login after a password change. Putting
  the merge at each of them is the failure mode `Fountain.Audit` and ADR 0013
  exist to remove: a sixth door is one forgotten line away from silently not
  being instrumented, and nothing fails when it is missed.

  So this keys on the transition itself. It reads the session's `user_id` on
  the way in, reads it again on the way out, and treats *absent becoming
  present* as a sign-in — whichever controller did it, for whatever reason.
  A new door is covered by construction.

  ## Reading posthog-js's cookie

  The anonymous id lives in the browser, in the cookie posthog-js writes for
  its own use: `ph_<project key>_posthog`, holding JSON with a `distinct_id`.
  Reading it is the whole of the server's involvement — it is not written, not
  persisted, and not recorded anywhere but the merge event itself.

  Everything here degrades to doing nothing: no cookie (an ad blocker, a
  visitor who never touched a public page, a sign-in through the API),
  unparseable JSON, a cookie from a different project key, or an id that
  already equals the account's. A merge that cannot be made is not an error;
  it means this person's history starts at their account, which is where it
  started for every account before this plug existed.
  """

  @behaviour Plug

  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Read *now*, on the way in. Reading it inside the callback would read the
    # session the response is about to write, which is the same value on both
    # sides and would make every sign-in look like an ordinary request.
    before = Plug.Conn.get_session(conn, :user_id)

    Plug.Conn.register_before_send(conn, &stitch(&1, before))
  end

  # `before` is the user_id as it was when the request arrived, captured by the
  # closure above; `conn` is the response. Only nil -> id is a sign-in: an id
  # changing to a *different* id would be a session swap, which nothing does,
  # and an unchanged id is every other request in the console.
  defp stitch(conn, before) do
    after_ = Plug.Conn.get_session(conn, :user_id)

    if is_nil(before) and is_binary(after_) do
      Fountain.Analytics.alias_anonymous(after_, anonymous_id(conn))
    end

    conn
  rescue
    # Identity stitching runs on the way out of a sign-in. It must never be
    # the reason one fails.
    e ->
      Logger.warning("analytics: identity stitch failed: #{inspect(e)}")
      conn
  end

  defp anonymous_id(conn) do
    with config when is_map(config) <- Fountain.Analytics.browser_config(),
         conn = Plug.Conn.fetch_cookies(conn),
         raw when is_binary(raw) <- conn.cookies[cookie_name(config.api_key)],
         {:ok, %{"distinct_id" => id}} when is_binary(id) <- Jason.decode(raw) do
      id
    else
      _ -> nil
    end
  end

  # posthog-js names its cookie after the project key, so a browser that has
  # visited two PostHog-instrumented sites keeps their ids apart. Matching on
  # the full name means a cookie left by a *different* project is ignored
  # rather than merged into this one's person.
  defp cookie_name(api_key), do: "ph_" <> api_key <> "_posthog"
end
