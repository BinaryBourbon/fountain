defmodule FountainWeb.TeamLiveCommsTest do
  # The teammate email/phone affordance on /team (flag `team_comms`). Flips
  # the flag through global app env, so not async; the providers are the
  # Req.Test plugs from config/test.exs, allowed to the LiveView process.
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.Team
  alias Fountain.Team.Comms
  alias Fountain.Team.Comms.{AgentMail, AgentPhone}

  setup do
    previous = Application.get_env(:fountain, :feature_flag_overrides)
    on_exit(fn -> restore(:feature_flag_overrides, previous) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp flag(on?),
    do: Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => on?})

  defp teammate(user) do
    agent = insert_agent(user_id: user.id, name: "Ada")

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Team.channel()
    )

    agent
  end

  defp stub_providers_ok do
    Req.Test.stub(AgentMail, fn conn ->
      case conn.method do
        "POST" -> Req.Test.json(conn, %{"inbox_id" => "inbox_1", "email" => "ada-1@agentmail.to"})
        "DELETE" -> Req.Test.json(conn, %{})
      end
    end)

    Req.Test.stub(AgentPhone, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/agents"} -> Req.Test.json(conn, %{"id" => "agt_1"})
        {"POST", _} -> Req.Test.json(conn, %{"id" => "num_1", "phoneNumber" => "+15551234567"})
        {"DELETE", _} -> Req.Test.json(conn, %{})
      end
    end)
  end

  test "with the flag off there is no affordance", %{conn: conn} do
    flag(false)
    user = insert_verified_user()
    agent = teammate(user)

    {:ok, _view, html} = conn |> login_user(user) |> live(~p"/team/#{agent.id}")
    refute html =~ "provision-contact-button"
    refute html =~ "teammate-contact"
  end

  test "with the flag on: give, see, release", %{conn: conn} do
    flag(true)
    user = insert_verified_user()
    agent = teammate(user)
    stub_providers_ok()

    {:ok, view, html} = conn |> login_user(user) |> live(~p"/team/#{agent.id}")
    assert html =~ "Give email &amp; phone"
    refute html =~ "release-contact-button"

    # The LiveView process makes the provider calls; let it use our stubs.
    Req.Test.allow(AgentMail, self(), view.pid)
    Req.Test.allow(AgentPhone, self(), view.pid)

    # The button opens the form that collects the number; nothing is bought yet.
    html = view |> element("#provision-contact-button") |> render_click()
    assert html =~ "contact-form"
    refute html =~ "ada-1@agentmail.to"

    html =
      view
      |> form("#contact-form", %{"prompt_from_number" => "(555) 000-1111"})
      |> render_submit()

    assert html =~ "ada-1@agentmail.to"
    assert html =~ "+15551234567"
    assert html =~ "texts from"
    assert html =~ "+15550001111"
    assert html =~ "release-contact-button"
    refute html =~ "provision-contact-button"
    assert %Fountain.Team.Contact{} = Comms.get_contact(user.id, agent.id)

    # Change the sender number without buying anything.
    Req.Test.stub(AgentMail, fn _ -> flunk("no provider call on change") end)
    Req.Test.stub(AgentPhone, fn _ -> flunk("no provider call on change") end)
    view |> element("#change-contact-number") |> render_click()

    html =
      view |> form("#contact-form", %{"prompt_from_number" => "555 000 2222"}) |> render_submit()

    assert html =~ "+15550002222"
    refute html =~ "+15550001111"

    stub_providers_ok()
    Req.Test.allow(AgentMail, self(), view.pid)
    Req.Test.allow(AgentPhone, self(), view.pid)
    html = view |> element("#release-contact-button") |> render_click()
    refute html =~ "ada-1@agentmail.to"
    assert html =~ "provision-contact-button"
    assert Comms.get_contact(user.id, agent.id) == nil
  end

  test "with the flag on but no provider keys the button is disabled and says why", %{conn: conn} do
    flag(true)
    user = insert_verified_user()
    agent = teammate(user)
    previous = Application.get_env(:fountain, :agentmail_api_key)
    Application.delete_env(:fountain, :agentmail_api_key)
    on_exit(fn -> Application.put_env(:fountain, :agentmail_api_key, previous) end)

    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/team/#{agent.id}")
    button = view |> element("#provision-contact-button") |> render()
    assert button =~ "disabled"
    assert button =~ "no AgentMail/AgentPhone keys"
  end
end
