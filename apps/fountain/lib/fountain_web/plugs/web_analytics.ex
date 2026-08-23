defmodule FountainWeb.Plugs.WebAnalytics do
  @moduledoc """
  Marks a route as part of the public surface, so the layout loads posthog-js.

  ## Why the server-side pageview was not enough

  `FountainWeb.Live.Hooks` captures `$pageview` from the server for every
  console page, and that was the whole of Fountain's web analytics. It answers
  which pages a signed-in operator opens, and nothing else, because a
  synthesised pageview has none of the properties the questions need:

    * no `$session_id`, so **sessions are zero** — bounce rate, session
      duration, entry and exit pages have no input at all;
    * no `$referrer`, no UTM parameters, so acquisition is unanswerable;
    * no `$browser`, `$os` or `$device_type`;
    * and, decisively, `Fountain.Analytics.capture/4` drops an event with no
      subject, so **nobody who is not signed in is counted**. The landing
      page, the manual and the register form — every page a visitor sees
      before they are a person — produced nothing.

  A browser snippet is the only thing that has those properties, because they
  are facts about the browser. So the public pages get one.

  ## The console still does not get one

  This plug is deliberately **not** on the console's pipelines. That decision
  stands and its reasons are in `FountainWeb.Live.Hooks`: the console is an
  operator surface behind a login, its pages are LiveView, and the server
  already holds everything worth recording about them. Running both there
  would also double every pageview in the project, since the hook does not
  know a snippet exists.

  The seam between the two is `Fountain.Analytics.alias_anonymous/2`, called
  by `FountainWeb.Plugs.AnalyticsIdentity` when a session begins: the visitor
  the snippet recorded and the account the server records become one person.

  ## Surfaces

  Every event the snippet sends carries `surface: "public"`, matching the
  `surface: "console"` the hook sets, so the two halves stay separable in a
  project that now receives both.

  ## The CSP is widened here, not in the router

  `FountainWeb.Router`'s `@csp` names no PostHog origin, which keeps the
  console's policy exactly as tight as it was — it loads no analytics script,
  so it has no business permitting one. This plug appends the two origins to
  `script-src` and `connect-src` on the responses that do load it.

  It has to happen at runtime rather than in the attribute: `POSTHOG_HOST` is
  read in `config/runtime.exs`, so a compile-time entry would carry whatever
  the *build* saw — for a release, nothing — and would block every
  self-hosted PostHog behind a header that looked correct in the source.

  PostHog Cloud serves ingestion and static assets from two different origins,
  and both are needed: one to fetch `array.js`, one to `POST` to `/batch/`.
  `Fountain.Analytics.assets_host/1` derives the second from the first so
  `POSTHOG_HOST` stays the only thing an operator sets.
  """

  @behaviour Plug

  @widened ~w(script-src connect-src)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Fountain.Analytics.browser_config() do
      nil ->
        conn

      config ->
        conn
        |> Plug.Conn.assign(:web_analytics, config)
        |> allow_posthog(Fountain.Analytics.browser_origins())
    end
  end

  defp allow_posthog(conn, []), do: conn

  defp allow_posthog(conn, origins) do
    case Plug.Conn.get_resp_header(conn, "content-security-policy") do
      [csp | _] ->
        Plug.Conn.put_resp_header(conn, "content-security-policy", widen(csp, origins))

      # No policy to widen. Adding one here would be inventing a second source
      # of truth for a header the :browser pipeline owns.
      [] ->
        conn
    end
  end

  defp widen(csp, origins) do
    csp
    |> String.split(";")
    |> Enum.map_join("; ", &widen_directive(String.trim(&1), origins))
  end

  defp widen_directive(directive, origins) do
    case String.split(directive, " ") do
      [name | sources] when name in @widened ->
        # `--` rather than a blind append: the header is rewritten on every
        # public response, and a proxy or a future plug that has already added
        # one of these origins must not make the directive grow each time.
        Enum.join([directive | origins -- sources], " ")

      _ ->
        directive
    end
  end
end
