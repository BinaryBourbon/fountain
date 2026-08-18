defmodule FountainWeb.TeamLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Team

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  describe "auth" do
    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/team")
      assert path =~ "/auth/login"
    end
  end

  describe "empty team" do
    test "invites the user to add a teammate", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/team")

      assert html =~ "No one on the team yet"
      assert html =~ "Add a teammate"
    end

    test "the picker lists agents not yet on the team", %{conn: conn} do
      user = insert_verified_user()
      insert_agent(user_id: user.id, name: "Ada")
      linus = insert_agent(user_id: user.id, name: "Linus")
      insert_teammate_conv(user, linus)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/team")
      html = view |> element("#add-teammate-button") |> render_click()

      assert html =~ "Add a teammate"
      assert html =~ "Ada"
      # Linus is on the team already: exactly one Add button, and it is Ada's.
      assert [_one] = Regex.scan(~r/phx-click="add_teammate"/, html)
    end
  end

  describe "roster" do
    test "lists teammates and opens the most recently active one", %{conn: conn} do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      linus = insert_agent(user_id: user.id, name: "Linus")
      ada_conv = insert_teammate_conv(user, ada)
      linus_conv = insert_teammate_conv(user, linus)
      insert_turn(ada_conv, prompt: "old ada prompt", status: "completed")
      t = insert_turn(linus_conv, prompt: "latest linus prompt", status: "completed")

      # Clearly after both rows' second-precision inserted_at, whatever the
      # clock did between the inserts.
      insert_log_event(linus_conv,
        turn_id: t.id,
        stream: "acp",
        data: acp_text("All green."),
        inserted_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

      conn = login_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/team")

      assert html =~ "Ada"
      assert html =~ "Linus"
      # Linus has the newest activity → selected → his transcript is open.
      assert page_title(view) =~ "Linus"
      assert render(view) =~ "latest linus prompt"
      # The roster previews the reply, not the prompt, once there is one.
      assert has_element?(view, "#teammate-#{linus.id}", "All green.")
      assert has_element?(view, "#teammate-#{ada.id}", "You: old ada prompt")
    end

    test "/team/:agent_id opens that teammate", %{conn: conn} do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      linus = insert_agent(user_id: user.id, name: "Linus")
      insert_teammate_conv(user, ada)
      linus_conv = insert_teammate_conv(user, linus)
      insert_turn(linus_conv, prompt: "hey linus", status: "completed")

      conn = login_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/team/#{linus.id}")

      assert page_title(view) =~ "Linus"
      assert has_element?(view, "#team-thread-#{linus_conv.id}", "hey linus")

      # Patching to Ada swaps the thread.
      view |> element("#teammate-#{ada.id} a") |> render_click()
      assert page_title(view) =~ "Ada"
      refute has_element?(view, "#team-thread-#{linus_conv.id}")
    end

    test "an agent not on the team is bounced back to /team", %{conn: conn} do
      user = insert_verified_user()
      stranger = insert_agent(user_id: user.id, name: "Stranger")
      conn = login_user(conn, user)

      # The bounce happens in handle_params on the static mount, which the
      # test client sees as a redirect carrying the flash.
      assert {:error, {:live_redirect, %{to: "/team", flash: flash}}} =
               live(conn, ~p"/team/#{stranger.id}")

      assert flash["error"] =~ "not on your team"
    end

    test "another tenant's teammates are not visible", %{conn: conn} do
      user = insert_verified_user()
      other = insert_verified_user()
      insert_teammate_conv(other, insert_agent(user_id: other.id, name: "Secret"))
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/team")
      refute html =~ "Secret"
    end
  end

  describe "live updates" do
    test "output for the open thread appends to the transcript", %{conn: conn} do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, status: "running")
      turn = insert_turn(conv, prompt: "say hi", status: "running")
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/team/#{ada.id}")
      assert render(view) =~ "say hi"

      ev =
        insert_log_event(conv,
          turn_id: turn.id,
          stream: "acp",
          data: acp_text("hi there!"),
          inserted_at: DateTime.utc_now()
        )

      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, ev})

      assert render(view) =~ "hi there!"
    end

    test "output for another teammate marks that row unread", %{conn: conn} do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id, name: "Ada")
      linus = insert_agent(user_id: user.id, name: "Linus")
      ada_conv = insert_teammate_conv(user, ada)
      linus_conv = insert_teammate_conv(user, linus)
      # Both read (last_read_at is not castable; mark_read is the writer).
      Fountain.Conversations.mark_read(ada_conv.id, user.id)
      Fountain.Conversations.mark_read(linus_conv.id, user.id)
      conn = login_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/team/#{ada.id}")
      refute has_element?(view, "#teammate-#{linus.id} [title=Unread]")

      ev =
        insert_log_event(linus_conv,
          stream: "acp",
          data: acp_text("psst"),
          inserted_at: DateTime.add(DateTime.utc_now(), 10, :second)
        )

      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{linus_conv.id}", {:log_event, ev})

      assert has_element?(view, "#teammate-#{linus.id} [title=Unread]")
      refute has_element?(view, "#teammate-#{ada.id} [title=Unread]")
    end
  end

  describe "read-only when the subscription lapsed" do
    test "the composer is replaced by a billing notice and sends are refused", %{conn: conn} do
      user = insert_verified_user()

      {:ok, user} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "canceled"})
        |> Fountain.Repo.update()

      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada)
      conn = login_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/team/#{ada.id}")

      assert html =~ "Read-only"
      refute has_element?(view, "#team-composer")

      html = render_click(view, "send", %{"prompt" => "hello"})
      assert html =~ "read-only"

      html = render_click(view, "open_picker", %{})
      refute html =~ "Add a teammate</h2>"
    end
  end
end

# Add / remove / send drive the conversation server, stubbed with Mimic in
# global mode so the LiveView process sees the stubs — which rules out
# async: true, hence the separate module (same convention as NewSubmitTest).
defmodule FountainWeb.TeamLiveMutationsTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Team

  setup :set_mimic_global

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  setup do
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    :ok
  end

  test "adding a teammate opens their conversation and selects them", %{conn: conn} do
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id, name: "Ada")
    conn = login_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/team")
    view |> element("#add-teammate-button") |> render_click()

    view
    |> element("button[phx-click=add_teammate][phx-value-agent_id='#{ada.id}']")
    |> render_click()

    assert_patch(view, ~p"/team/#{ada.id}")
    assert has_element?(view, "#teammate-#{ada.id}")
    assert [%{agent: %{id: id}}] = Team.list_teammates(user.id)
    assert id == ada.id
  end

  test "sending a message hands it to the conversation server and clears the box", %{conn: conn} do
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id, name: "Ada")
    conv = insert_teammate_conv(user, ada)
    test_pid = self()

    stub(ConversationServer, :send_prompt, fn id, text, _images, _opts ->
      send(test_pid, {:sent, id, text})
      :ok
    end)

    conn = login_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/team/#{ada.id}")

    view |> form("#team-composer", %{"prompt" => "  hello Ada  "}) |> render_submit()

    conv_id = conv.id
    assert_received {:sent, ^conv_id, "hello Ada"}
    assert_push_event(view, "clear_composer", %{})
  end

  test "a busy teammate is reported, not re-sent to", %{conn: conn} do
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id, name: "Ada")
    insert_teammate_conv(user, ada, status: "running")
    stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)

    conn = login_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/team/#{ada.id}")

    html = view |> form("#team-composer", %{"prompt" => "hurry"}) |> render_submit()
    assert html =~ "still working"
  end

  test "removing a teammate empties the roster and returns to /team", %{conn: conn} do
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id, name: "Ada")
    insert_teammate_conv(user, ada)
    conn = login_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/team/#{ada.id}")
    view |> element("button[phx-click=remove_teammate]") |> render_click()

    assert_patch(view, ~p"/team")
    assert Team.list_teammates(user.id) == []
    assert render(view) =~ "No one on the team yet"
  end
end
