defmodule FountainWeb.AnalyticsPageviewTest do
  @moduledoc """
  Console pageviews, captured server-side from the auth hook.

  The console ships no analytics snippet, so this hook is the only thing that
  says which pages an operator actually uses. It has to fire once per
  navigation — `handle_params` runs for the dead render as well as the
  connected one, and counting both would double every number in the project.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    previous = Application.get_env(:fountain, :posthog_project_api_key)
    Application.put_env(:fountain, :posthog_project_api_key, "phc_test")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fountain, :posthog_project_api_key)
        key -> Application.put_env(:fountain, :posthog_project_api_key, key)
      end
    end)

    test = self()

    Req.Test.stub(Fountain.Analytics, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posthog, Jason.decode!(body)})
      Req.Test.json(conn, %{"status" => 1})
    end)

    # After the stub, so registering the account does not drop four events on
    # the floor and log about it.
    user = insert_verified_user()

    {:ok, conn: login_user(conn, user), user: user}
  end

  defp pageviews do
    receive do
      {:posthog, %{"batch" => batch}} ->
        Enum.filter(batch, &(&1["event"] == "$pageview")) ++ pageviews()
    after
      0 -> []
    end
  end

  test "visiting a console page captures one pageview for the signed-in account", %{
    conn: conn,
    user: user
  } do
    {:ok, _lv, _html} = live(conn, ~p"/dashboard")

    assert [pageview] = pageviews()
    assert pageview["distinct_id"] == user.id
    assert pageview["properties"]["$pathname"] == "/dashboard"
    assert pageview["properties"]["surface"] == "console"
  end

  test "with no PostHog key nothing is captured", %{conn: conn} do
    Application.delete_env(:fountain, :posthog_project_api_key)

    {:ok, _lv, _html} = live(conn, ~p"/dashboard")

    assert pageviews() == []
  end
end
