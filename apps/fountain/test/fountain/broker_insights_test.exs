defmodule Fountain.Broker.Native.InsightsTest do
  @moduledoc """
  The admin overview of the broker: counts, splits and lists derived from
  `broker_requests` and `broker_sessions`, every one bounded by the window.
  Rows are written straight into the log table here, the way the
  `RequestLog` writer does, so the shape under test is the table's.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Broker.Native.{Insights, Request, Sessions}

  defp log!(user, conv, attrs) do
    base = %{
      conversation_id: conv.id,
      user_id: user.id,
      method: "GET",
      host: "api.example.com",
      path: "/v1/things",
      outcome: "passthrough",
      credential_keys: [],
      inserted_at: DateTime.utc_now()
    }

    Repo.insert!(struct!(Request, Map.merge(base, Map.new(attrs))))
  end

  defp ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    %{user: user, conv: conv}
  end

  test "an empty log reads as zeros, not nils", %{} do
    overview = Insights._unsafe_overview_admin(24)

    assert overview.window == %{
             requests: 0,
             conversations: 0,
             tenants: 0,
             injected: 0,
             passthrough: 0,
             denied: 0,
             failed: 0
           }

    assert overview.sessions == %{live: 0, expired: 0, conversations: 0}
    assert overview.hosts == []
    assert overview.services == []
    assert overview.denied == []
    assert overview.failed == []
    assert overview.errors == []
    assert overview.live_sessions == []
    assert overview.window_hours == 24
    assert is_integer(overview.retention_hours)
  end

  test "the window splits requests by outcome and counts who produced them", %{
    user: user,
    conv: conv
  } do
    other = insert_verified_user()
    other_conv = insert_conversation(user_id: other.id, agent: insert_agent(user_id: other.id))

    log!(user, conv, outcome: "injected", service: "github", credential_keys: ["GITHUB_TOKEN"])
    log!(user, conv, outcome: "injected", service: "github", credential_keys: ["GITHUB_TOKEN"])
    log!(user, conv, outcome: "passthrough", host: "registry.npmjs.org")
    log!(other, other_conv, outcome: "denied", host: "evil.example")
    log!(other, other_conv, outcome: "passthrough", error: "client_closed")
    # Outside the window: counted by nothing below.
    log!(user, conv, outcome: "denied", inserted_at: ago(30))

    overview = Insights._unsafe_overview_admin(24)

    assert overview.window == %{
             requests: 5,
             conversations: 2,
             tenants: 2,
             injected: 2,
             passthrough: 2,
             denied: 1,
             failed: 1
           }

    assert [%{host: "api.example.com", requests: 3, injected: 2, denied: 0, failed: 1} | rest] =
             overview.hosts

    assert Enum.map(rest, & &1.host) |> Enum.sort() == ["evil.example", "registry.npmjs.org"]

    assert [
             %{
               service: "github",
               requests: 2,
               conversations: 1,
               credential_keys: ["GITHUB_TOKEN"]
             }
           ] =
             overview.services

    assert [%{host: "evil.example", email: email, conversation_id: denied_conv}] = overview.denied
    assert email == other.email
    assert denied_conv == other_conv.id

    assert [%{error: "client_closed", email: _}] = overview.failed
    assert overview.errors == [%{error: "client_closed", requests: 1}]
  end

  test "a wider window reaches older rows, and an unknown one falls back to a day", %{
    user: user,
    conv: conv
  } do
    log!(user, conv, outcome: "denied", inserted_at: ago(30))

    assert Insights._unsafe_overview_admin(168).window.denied == 1
    assert Insights._unsafe_overview_admin(24).window.denied == 0
    assert Insights._unsafe_overview_admin(1).window.denied == 0
    assert Insights._unsafe_overview_admin(999).window_hours == 24
  end

  test "the binding table merges the variable names a rule attached across rows", %{
    user: user,
    conv: conv
  } do
    log!(user, conv, outcome: "injected", service: "gh", credential_keys: ["GITHUB_TOKEN"])

    log!(user, conv,
      outcome: "injected",
      service: "gh",
      credential_keys: ["GH_TOKEN", "GITHUB_TOKEN"]
    )

    # A matched passthrough rule is not a credential and does not count here.
    log!(user, conv, outcome: "passthrough", service: nil, credential_keys: [])

    assert [%{service: "gh", requests: 2, credential_keys: ["GH_TOKEN", "GITHUB_TOKEN"]}] =
             Insights._unsafe_overview_admin(24).services
  end

  test "live sessions list who holds a token, what it brokers, and skip expired ones", %{
    user: user,
    conv: conv
  } do
    {:ok, _} =
      Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        rules: [],
        unmatched_host_policy: :deny,
        meta: %{
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "credential_keys" => %{"github" => ["GITHUB_TOKEN"], "openai" => ["OPENAI_API_KEY"]}
        },
        ttl_seconds: 600
      })

    # Already over: the reaper has not run, so it is on disk and counted as such.
    {:ok, _} =
      Sessions.create(%{
        conversation_id: conv.id,
        user_id: user.id,
        rules: [],
        meta: %{},
        ttl_seconds: 1
      })

    Repo.update_all(
      from(s in Fountain.Broker.Native.Session, where: s.unmatched_host_policy == "passthrough"),
      set: [expires_at: ago(1)]
    )

    overview = Insights._unsafe_overview_admin(24)

    assert overview.sessions == %{live: 1, expired: 1, conversations: 1}

    assert [session] = overview.live_sessions
    assert session.conversation_id == conv.id
    assert session.email == user.email
    assert session.policy == "deny"
    assert session.credential_keys == ["GITHUB_TOKEN", "OPENAI_API_KEY"]
    refute Map.has_key?(session, :rules_ciphertext)
    refute Map.has_key?(session, :token_hash)
  end

  test "a deleted tenant's rows go with the tenant", %{user: user, conv: conv} do
    log!(user, conv, outcome: "denied")
    # broker_requests.user_id cascades: the log is tenant data and leaves
    # with the account, so the page never has a row it cannot attribute.
    Repo.delete!(user)

    assert Insights._unsafe_overview_admin(24).denied == []
    assert Insights._unsafe_overview_admin(24).window.requests == 0
  end
end
