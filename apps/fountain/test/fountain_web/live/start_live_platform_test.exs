defmodule FountainWeb.StartLivePlatformTest do
  @moduledoc """
  The verified landing against platform inference (#1388 + #1390).

  This is the premise ADR 0038 rests on: an account that has supplied nothing
  but an email address can send the request on the landing and get a reply.
  The page asks `InferenceCredentials.select/2` rather than "does this tenant
  hold a key", so a deployment that turns a platform key on stops warning
  about a wall that is no longer there.

  `async: false`, and in its own module for that reason: platform keys live in
  the global application environment, and an async module that writes it races
  every module that reads it (#1214).
  """
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    original =
      for key <- [:platform_anthropic_api_key, :platform_openai_api_key],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "with a platform key for the agent's provider, the page warns about nothing",
       %{conn: conn} do
    Application.put_env(:fountain, :platform_anthropic_api_key, "sk-platform")

    {:ok, _lv, html} = live(conn, ~p"/start")

    refute html =~ "no inference credential yet"
  end

  test "a platform key for another provider does not cover a claude agent", %{conn: conn} do
    Application.delete_env(:fountain, :platform_anthropic_api_key)
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

    {:ok, _lv, html} = live(conn, ~p"/start")

    assert html =~ "no inference credential yet"
  end
end
