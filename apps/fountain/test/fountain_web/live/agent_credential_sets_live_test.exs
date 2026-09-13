defmodule FountainWeb.AgentCredentialSetsLiveTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest
  alias Fountain.{Agents, Crypto, InferenceCredentials, Repo}

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)

    {:ok, default} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "default-key")

    {:ok, second} = InferenceCredentials.create_set(user.id, "Customer subscription")
    agent = insert_agent(user_id: user.id, inference_credential_id: second.id)

    %{
      conn: login_user(conn, user),
      user: user,
      dek: dek,
      default: default,
      second: second,
      agent: agent
    }
  end

  test "mount, validate and inline save all use the selected set", %{
    conn: conn,
    user: user,
    dek: dek,
    default: default,
    second: second,
    agent: agent
  } do
    stub(Req, :get, fn _, _ -> {:ok, %Req.Response{status: 200}} end)
    {:ok, view, _} = live(conn, "/agents/#{agent.id}/edit")
    assert has_element?(view, "form[phx-submit=save_credential]")

    view |> form("#agent-form", %{"agent" => %{"name" => "Renamed"}}) |> render_change()
    assert has_element?(view, "form[phx-submit=save_credential]")
    assert has_element?(view, ~s(option[value="#{second.id}"][selected]))

    view
    |> form("form[phx-submit=save_credential]", %{"value" => "customer-key"})
    |> render_submit()

    refute has_element?(view, "form[phx-submit=save_credential]")

    assert {:ok, %{anthropic_api_key: "customer-key"}} =
             InferenceCredentials.decrypted_for_set(Repo.reload!(second), dek)

    assert {:ok, %{anthropic_api_key: "default-key"}} =
             InferenceCredentials.decrypted_for_set(Repo.reload!(default), dek)

    view |> form("#agent-form") |> render_submit()
    saved = Agents.get_agent(agent.id, user.id)
    assert saved.name == "Renamed"
    assert saved.inference_credential_id == second.id
  end

  test "changing the selection changes the missing credential card and persists the choice", %{
    conn: conn,
    agent: agent,
    default: default,
    second: second,
    user: user
  } do
    {:ok, view, _} = live(conn, "/agents/#{agent.id}/edit")

    view
    |> form("#agent-form", %{"agent" => %{"inference_credential_id" => default.id}})
    |> render_change()

    refute has_element?(view, "form[phx-submit=save_credential]")

    view
    |> form("#agent-form", %{"agent" => %{"inference_credential_id" => second.id}})
    |> render_change()

    assert has_element?(view, "form[phx-submit=save_credential]")
    view |> form("#agent-form") |> render_submit()
    assert Agents.get_agent(agent.id, user.id).inference_credential_id == second.id
  end

  test "only owned sets appear in the picker", %{conn: conn, agent: agent, second: second} do
    stranger = insert_verified_user()
    {:ok, foreign} = InferenceCredentials.create_set(stranger.id, "Foreign set")
    {:ok, view, _} = live(conn, "/agents/#{agent.id}/edit")

    assert has_element?(
             view,
             ~s(select[name="agent[inference_credential_id]"] option[value="#{second.id}"])
           )

    refute has_element?(view, ~s(option[value="#{foreign.id}"]))
  end

  test "deleted selection refuses inline save without writing the default", %{
    conn: conn,
    agent: agent,
    second: second,
    user: user,
    dek: dek
  } do
    reject(Req, :get, 2)
    {:ok, view, _} = live(conn, "/agents/#{agent.id}/edit")
    {:ok, _} = InferenceCredentials.delete_set(second)

    html =
      view
      |> form("form[phx-submit=save_credential]", %{"value" => "misdirected"})
      |> render_submit()

    assert html =~ "no longer available"

    assert {:ok, %{anthropic_api_key: "default-key"}} =
             InferenceCredentials.decrypted_for_user(user.id, dek)
  end

  test "a set deleted during provider validation is refused", %{
    conn: conn,
    agent: agent,
    second: second,
    user: user,
    dek: dek
  } do
    stub(Req, :get, fn _, _ ->
      {:ok, _} = InferenceCredentials.delete_set(second)
      {:ok, %Req.Response{status: 200}}
    end)

    {:ok, view, _} = live(conn, "/agents/#{agent.id}/edit")

    html =
      view
      |> form("form[phx-submit=save_credential]", %{"value" => "misdirected"})
      |> render_submit()

    assert html =~ "no longer available"

    assert {:ok, %{anthropic_api_key: "default-key"}} =
             InferenceCredentials.decrypted_for_user(user.id, dek)
  end

  test "a single set is hidden and its selected identity survives validation", %{
    conn: conn,
    user: user,
    default: default,
    second: second,
    agent: agent
  } do
    {:ok, _} = Agents.update_agent(agent, %{"inference_credential_id" => default.id})
    {:ok, _} = InferenceCredentials.delete_set(second)
    {:ok, view, _} = live(conn, "/agents/#{agent.id}/edit")
    refute has_element?(view, ~s(select[name="agent[inference_credential_id]"]))
    view |> form("#agent-form", %{"agent" => %{"name" => "Single"}}) |> render_change()
    view |> form("#agent-form") |> render_submit()
    assert Agents.get_agent(agent.id, user.id).inference_credential_id == default.id
  end
end
