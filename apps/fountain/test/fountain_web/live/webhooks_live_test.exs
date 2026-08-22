defmodule FountainWeb.WebhooksLiveTest do
  @moduledoc """
  `/account/webhooks` (#700, ADR 0024). The console has to do the four things
  an integrator cannot do from a `curl` they have already forgotten: see the
  secret once, send a test event, read every attempt, and send one again.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Webhooks

  defp endpoint_for(user, attrs \\ %{}) do
    {:ok, {endpoint, secret}} =
      Webhooks.create_endpoint(
        user.id,
        Map.merge(%{"url" => "https://hooks.example.com/f"}, attrs)
      )

    {endpoint, secret}
  end

  test "creating an endpoint reveals the secret exactly once", %{conn: conn} do
    user = insert_verified_user()
    conn = login_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/account/webhooks")

    assert html =~ "No webhook endpoints yet"

    html =
      lv
      |> form("form[phx-submit=create]", %{
        "url" => "https://hooks.example.com/f",
        "description" => "ci",
        # The three defaults are ticked in the rendered form, so this adds a
        # fourth rather than replacing them. It is what proves the checkbox
        # map is read at all.
        "events" => %{"conversation.sandbox.done" => "true"}
      })
      |> render_submit()

    assert [endpoint] = Webhooks.list_endpoints(user.id)
    assert "conversation.sandbox.done" in endpoint.event_types
    assert "conversation.turn.done" in endpoint.event_types
    assert endpoint.description == "ci"

    {:ok, secret} = Webhooks.secret(endpoint)
    assert html =~ secret

    # Dismissing it is the last time the page ever holds it.
    html = lv |> element("button", "I've copied it, dismiss") |> render_click()
    refute html =~ secret

    refute render(lv) =~ secret
  end

  test "a URL pointing somewhere private is refused in the form", %{conn: conn} do
    user = insert_verified_user()
    conn = login_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/account/webhooks")

    html =
      lv
      |> form("form[phx-submit=create]", %{"url" => "http://localhost:9000/hook", "events" => %{}})
      |> render_submit()

    assert html =~ "url"
    assert Webhooks.list_endpoints(user.id) == []
  end

  test "pausing and resuming an endpoint", %{conn: conn} do
    user = insert_verified_user()
    {endpoint, _} = endpoint_for(user)
    conn = login_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/account/webhooks")

    lv |> element("#endpoint-#{endpoint.id} button", "Pause") |> render_click()
    assert Webhooks.get_endpoint(endpoint.id, user.id).status == "disabled"

    lv |> element("#endpoint-#{endpoint.id} button", "Resume") |> render_click()
    assert Webhooks.get_endpoint(endpoint.id, user.id).status == "active"
  end

  test "rotating shows the new secret and invalidates the old", %{conn: conn} do
    user = insert_verified_user()
    {endpoint, first} = endpoint_for(user)
    conn = login_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/account/webhooks")

    html = lv |> element("#endpoint-#{endpoint.id} button", "Rotate secret") |> render_click()

    {:ok, second} = Webhooks.secret(Webhooks.get_endpoint(endpoint.id, user.id))
    refute first == second
    assert html =~ second
    refute html =~ first
  end

  test "the delivery panel shows the attempt and can send it again", %{conn: conn} do
    user = insert_verified_user()
    {endpoint, _} = endpoint_for(user)

    {:ok, delivery} =
      Webhooks.record_delivery(%{
        webhook_endpoint_id: endpoint.id,
        event_id: "42",
        event_type: "conversation.turn.done",
        attempt: 2,
        status_code: 500,
        duration_ms: 91,
        error: "HTTP 500",
        payload: %{"id" => "42", "type" => "conversation.turn.done"}
      })

    conn = login_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/account/webhooks")

    refute html =~ "conversation.turn.done\n"

    html = lv |> element("#endpoint-#{endpoint.id} button", "Recent deliveries") |> render_click()

    assert html =~ "conversation.turn.done"
    assert html =~ "500"
    assert html =~ "91ms"

    html = lv |> element("#delivery-#{delivery.id} button", "Send again") |> render_click()
    assert html =~ "Queued again"
  end

  test "sending a test event says where to look for the result", %{conn: conn} do
    user = insert_verified_user()
    {endpoint, _} = endpoint_for(user)
    conn = login_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/account/webhooks")

    html = lv |> element("#endpoint-#{endpoint.id} button", "Send test event") |> render_click()

    assert html =~ "Test event queued"
  end

  test "deleting removes the endpoint and its panel", %{conn: conn} do
    user = insert_verified_user()
    {endpoint, _} = endpoint_for(user)
    conn = login_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/account/webhooks")

    lv |> element("#endpoint-#{endpoint.id} button", "Delete") |> render_click()

    assert Webhooks.list_endpoints(user.id) == []
    assert render(lv) =~ "No webhook endpoints yet"
  end

  test "another account's endpoint is not on the page", %{conn: conn} do
    user = insert_verified_user()
    stranger = insert_verified_user()
    {theirs, _} = endpoint_for(stranger, %{"url" => "https://not-yours.example.com/h"})

    conn = login_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/account/webhooks")

    refute html =~ "not-yours.example.com"
    refute html =~ theirs.id
  end
end
