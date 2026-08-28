defmodule Fountain.AppsTest do
  @moduledoc """
  The one place that knows where the browser apps live (#866). Every link
  that leaves the console — an email, a forwarded support report, a retired
  route's redirect — reads it from here, so they cannot drift apart.
  """

  use ExUnit.Case, async: false

  doctest Fountain.Apps

  alias Fountain.Apps

  setup do
    original = {
      Application.fetch_env(:fountain, :conversations_app_url),
      Application.fetch_env(:fountain, :team_app_url)
    }

    on_exit(fn ->
      case original do
        {{:ok, c}, {:ok, t}} ->
          Application.put_env(:fountain, :conversations_app_url, c)
          Application.put_env(:fountain, :team_app_url, t)

        _ ->
          Application.delete_env(:fountain, :conversations_app_url)
          Application.delete_env(:fountain, :team_app_url)
      end
    end)

    :ok
  end

  test "defaults to the hosted apps" do
    Application.delete_env(:fountain, :conversations_app_url)
    Application.delete_env(:fountain, :team_app_url)

    assert Apps.conversations() == "https://fountain-conversations.demo.managoat.com/"
    assert Apps.team() == "https://fountain-team.demo.managoat.com/"
  end

  test "a configured URL wins, with exactly one trailing slash either way" do
    Application.put_env(:fountain, :conversations_app_url, "https://apps.example.com/convs")
    Application.put_env(:fountain, :team_app_url, "https://apps.example.com/team/")

    assert Apps.conversations() == "https://apps.example.com/convs/"
    assert Apps.team() == "https://apps.example.com/team/"
    assert Apps.conversation_url("c1") == "https://apps.example.com/convs/#/c/c1"
  end

  test "an empty string means this deployment has no such app" do
    Application.put_env(:fountain, :conversations_app_url, "")
    Application.put_env(:fountain, :team_app_url, "")

    assert Apps.conversations() == nil
    assert Apps.team() == nil
    assert Apps.conversation_url("c1") == nil
    assert Apps.new_conversation_url() == nil
    assert Apps.team_url() == nil
    assert Apps.team_url("a1") == nil
  end

  test "deep links follow the apps' own hash routes" do
    Application.put_env(:fountain, :conversations_app_url, "https://x.test/c/")
    Application.put_env(:fountain, :team_app_url, "https://x.test/t/")

    assert Apps.conversation_url("abc") == "https://x.test/c/#/c/abc"
    assert Apps.conversation_url("abc", logs: true) == "https://x.test/c/#/c/abc/logs"
    assert Apps.new_conversation_url() == "https://x.test/c/#/new"
    assert Apps.team_url() == "https://x.test/t/"
    assert Apps.team_url("agent-1") == "https://x.test/t/#/team/agent-1"
  end
end
