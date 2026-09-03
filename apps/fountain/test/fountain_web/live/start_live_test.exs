defmodule FountainWeb.StartLiveTest do
  @moduledoc """
  `/start`, the verified landing (ADR 0038, #1390): a key, one request, the
  reply on the same screen.
  """
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.{Accounts, Onboarding}

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  defp reply!(user, text \\ "I am on Linux, in /work.") do
    conv = insert_conversation(user_id: user.id)

    turn =
      insert_turn(conv, %{
        status: "completed",
        reply_text: text,
        ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {conv, turn}
  end

  describe "the key" do
    test "is minted on the first view and shown once", %{conn: conn, user: user} do
      assert Accounts.list_api_keys(user.id) == []

      {:ok, _lv, html} = live(conn, ~p"/start")

      assert [key] = Accounts.list_api_keys(user.id)
      assert html =~ key.key_prefix
      assert html =~ "Shown once"
    end

    test "is not silently minted a second time on a later view", %{conn: conn, user: user} do
      {:ok, _lv, _html} = live(conn, ~p"/start")
      assert length(Accounts.list_api_keys(user.id)) == 1

      {:ok, lv, html} = live(conn, ~p"/start")

      assert length(Accounts.list_api_keys(user.id)) == 1
      assert html =~ "a key is shown once"

      # ...but the page can hand out another when asked.
      html = lv |> element("button", "Create another key") |> render_click()
      assert length(Accounts.list_api_keys(user.id)) == 2
      assert html =~ "Shown once"
    end

    # Found by walking the real path: the mint happens on the connected mount,
    # so the dead render has no raw key — and it used to tell an account with
    # no key at all that it already had one.
    test "the dead render does not claim a key that does not exist", %{conn: conn} do
      html = conn |> Phoenix.ConnTest.get(~p"/start") |> Phoenix.ConnTest.html_response(200)

      assert html =~ "This account has no API key yet"
      refute html =~ "already has a key"
    end

    test "the mint is attributed to the console, not to the system", %{conn: conn, user: user} do
      {:ok, _lv, _html} = live(conn, ~p"/start")

      events = Fountain.Audit.list_recent_for_user(user.id)
      mint = Enum.find(events, &(&1.action == "api_key.created"))

      assert mint.actor == "ui"
    end
  end

  # BYO inference (ADR 0008) is still the one wall on this path. #1388 is what
  # removes it; until then the page says so rather than letting a pasted
  # request fail with a refusal the reader has to decode.
  describe "the inference credential" do
    test "an account with none is told before it pastes anything", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ "no inference credential yet"
      assert html =~ "/account/inference-credentials"
    end

    test "an account with one is not", %{conn: conn, user: user} do
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Fountain.InferenceCredentials.put_credential(
          user.id,
          dek,
          :anthropic_api_key,
          "sk-ant-test-key-000000000000",
          actor: "ui"
        )

      {:ok, _lv, html} = live(conn, ~p"/start")

      refute html =~ "no inference credential yet"
    end
  end

  describe "the request" do
    test "carries the real key and the account's agent", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id, name: "starter")

      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ agent.id
      assert html =~ "/api/conversations"
      assert html =~ "starter"

      for token <- Onboarding.placeholders() do
        refute html =~ token
      end
    end

    test "says so plainly when there is no agent to run against", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ "You have no agent yet"
      assert html =~ "/agents/new"
    end

    test "prefers a starter agent over the account's other agents", %{conn: conn, user: user} do
      _other = insert_agent(user_id: user.id, name: "aardvark")
      starter = insert_agent(user_id: user.id, name: "starter")

      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ starter.id
    end
  end

  describe "the reply" do
    test "says nothing has run before anything has", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ "Nothing has run on this account yet"
    end

    test "says the request is running once a conversation exists", %{conn: conn, user: user} do
      insert_conversation(user_id: user.id)

      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ "Your request is running"
    end

    test "shows the account's first reply on the page", %{conn: conn, user: user} do
      {conv, _turn} = reply!(user)

      {:ok, _lv, html} = live(conn, ~p"/start")

      assert html =~ "I am on Linux, in /work."
      assert html =~ "That reply came from your agent"
      assert html =~ conv.id
    end

    test "arrives without a reload when the account is nudged", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/start")
      refute html =~ "That reply came from your agent"

      reply!(user, "Ubuntu, /work/app.")
      send(lv.pid, {:sidebar_update, user.id})

      html = render(lv)
      assert html =~ "Ubuntu, /work/app."
      assert html =~ "That reply came from your agent"
    end
  end

  test "the three doors are below the fold", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/start")

    assert html =~ "/account/inference-credentials"
    assert html =~ "/docs/cli"
    assert html =~ "/docs/sdk"
  end

  test "an unauthenticated visitor is sent to login", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/start")
    assert path =~ "/auth/login"
  end
end
