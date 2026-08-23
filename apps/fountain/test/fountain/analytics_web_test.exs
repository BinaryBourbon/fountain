defmodule Fountain.AnalyticsWebTest do
  @moduledoc """
  The three things that made web analytics and API usage unanswerable.

  Every assertion here failed before the change that introduced it, and the
  first two failed *silently* — the project had a full pipeline delivering
  events that could not answer the question they were collected for.
  """

  # Mutates global app env (the PostHog key, the host, the browser switch).
  use ExUnit.Case, async: false

  alias Fountain.Analytics

  @user_id "22222222-2222-2222-2222-222222222222"
  @anon_id "0198c0de-anon-4b0d-9c1e-000000000001"

  setup do
    previous = %{
      key: Application.get_env(:fountain, :posthog_project_api_key),
      host: Application.get_env(:fountain, :posthog_host),
      enabled: Application.get_env(:fountain, :analytics_enabled),
      browser: Application.get_env(:fountain, :analytics_browser_capture)
    }

    Fountain.FeatureFlags.reset()

    on_exit(fn ->
      restore(:posthog_project_api_key, previous.key)
      restore(:posthog_host, previous.host)
      restore(:analytics_enabled, previous.enabled)
      restore(:analytics_browser_capture, previous.browser)
      Fountain.FeatureFlags.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp posthog_on, do: Application.put_env(:fountain, :posthog_project_api_key, "phc_test")

  defp stub_capture do
    test = self()

    Req.Test.stub(Analytics, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posthog, Jason.decode!(body)})
      Req.Test.json(conn, %{"status" => 1})
    end)
  end

  ## ── Location ──────────────────────────────────────────────────────────────

  describe "geolocation" do
    setup do
      posthog_on()
      stub_capture()
      :ok
    end

    test "a capture with no client address disables enrichment rather than omitting $ip" do
      # The bug this replaces: `"$ip" => nil` was believed to mean "no
      # location". PostHog reads a null or missing $ip as "use the address the
      # batch arrived from" and geolocates the sending pod, which put every
      # pageview in the Fountain project in one city.
      Analytics.capture("agent.created", @user_id)

      assert_receive {:posthog, %{"batch" => [event]}}
      assert event["properties"]["$geoip_disable"] == true
      refute Map.has_key?(event["properties"], "$ip")
    end

    test "a request-scoped capture forwards the client address and does not disable enrichment" do
      Analytics.capture("agent.created", @user_id, %{}, request_ip: "203.0.113.7")

      assert_receive {:posthog, %{"batch" => [event]}}
      assert event["properties"]["$ip"] == "203.0.113.7"
      refute Map.has_key?(event["properties"], "$geoip_disable")
    end

    test "an empty client address is treated as no address, not as an address" do
      Analytics.capture("agent.created", @user_id, %{}, request_ip: "")

      assert_receive {:posthog, %{"batch" => [event]}}
      assert event["properties"]["$geoip_disable"] == true
      refute Map.has_key?(event["properties"], "$ip")
    end
  end

  ## ── Browser snippet configuration ─────────────────────────────────────────

  describe "assets_host/1" do
    test "PostHog Cloud serves assets from a different origin than ingestion" do
      assert Analytics.assets_host("https://us.i.posthog.com") ==
               "https://us-assets.i.posthog.com"

      assert Analytics.assets_host("https://eu.i.posthog.com") ==
               "https://eu-assets.i.posthog.com"
    end

    test "a trailing slash does not defeat the match" do
      assert Analytics.assets_host("https://us.i.posthog.com/") ==
               "https://us-assets.i.posthog.com"
    end

    test "a self-hosted instance serves both from one origin" do
      assert Analytics.assets_host("https://posthog.internal.example") ==
               "https://posthog.internal.example"

      assert Analytics.assets_host("https://posthog.internal.example/") ==
               "https://posthog.internal.example"
    end
  end

  describe "browser_origins/0" do
    test "names both origins for cloud, so the CSP admits the script and the ingest" do
      Application.put_env(:fountain, :posthog_host, "https://us.i.posthog.com")

      assert Analytics.browser_origins() == [
               "https://us.i.posthog.com",
               "https://us-assets.i.posthog.com"
             ]
    end

    test "names one origin for a self-hosted instance" do
      Application.put_env(:fountain, :posthog_host, "https://posthog.internal.example")

      assert Analytics.browser_origins() == ["https://posthog.internal.example"]
    end

    test "is independent of whether capture is on — the CSP is one shared header" do
      Application.delete_env(:fountain, :posthog_project_api_key)
      Application.put_env(:fountain, :posthog_host, "https://us.i.posthog.com")

      assert length(Analytics.browser_origins()) == 2
    end
  end

  describe "browser_config/0" do
    test "is nil with no project key, so a self-hoster loads no third-party script" do
      Application.delete_env(:fountain, :posthog_project_api_key)

      assert Analytics.browser_config() == nil
    end

    test "is nil when POSTHOG_BROWSER_CAPTURE is off, with server capture untouched" do
      posthog_on()
      Application.put_env(:fountain, :analytics_browser_capture, false)

      assert Analytics.browser_config() == nil
      assert Analytics.enabled?()
    end

    test "is nil when capture as a whole is off" do
      posthog_on()
      Application.put_env(:fountain, :analytics_enabled, false)

      assert Analytics.browser_config() == nil
    end

    test "carries the same project key the server sends with" do
      posthog_on()
      Application.put_env(:fountain, :posthog_host, "https://us.i.posthog.com")

      # One project on purpose: the visitor's anonymous pageviews and the
      # account's server-side events have to be joinable, and a merge across
      # two projects is not a thing PostHog can do.
      assert %{
               api_key: "phc_test",
               api_host: "https://us.i.posthog.com",
               assets_host: "https://us-assets.i.posthog.com"
             } = Analytics.browser_config()
    end
  end

  ## ── Anonymous → account ───────────────────────────────────────────────────

  describe "alias_anonymous/2" do
    setup do
      posthog_on()
      stub_capture()
      :ok
    end

    test "merges the anonymous person into the account" do
      Analytics.alias_anonymous(@user_id, @anon_id)

      assert_receive {:posthog, %{"batch" => [event]}}
      assert event["event"] == "$identify"
      assert event["distinct_id"] == @user_id
      assert event["properties"]["$anon_distinct_id"] == @anon_id
    end

    test "sends nothing when there is no anonymous id" do
      Req.Test.stub(Analytics, fn _conn -> flunk("PostHog should not be called") end)

      assert :ok = Analytics.alias_anonymous(@user_id, nil)
      assert :ok = Analytics.alias_anonymous(@user_id, "")
    end

    test "sends nothing when the two ids are already the same" do
      # A returning visitor whose browser already identified as the account.
      # Merging a person into itself is a write PostHog does not need.
      Req.Test.stub(Analytics, fn _conn -> flunk("PostHog should not be called") end)

      assert :ok = Analytics.alias_anonymous(@user_id, @user_id)
    end

    test "sends nothing when there is no account to merge into" do
      Req.Test.stub(Analytics, fn _conn -> flunk("PostHog should not be called") end)

      assert :ok = Analytics.alias_anonymous(nil, @anon_id)
    end
  end

  ## ── API usage ─────────────────────────────────────────────────────────────

  describe "api_request/1" do
    test "recognises the :api pipeline's request-log actions" do
      assert Analytics.api_request("POST /api/conversations") ==
               {:ok, {"POST", "/api/conversations"}}

      assert Analytics.api_request("DELETE /api/environments/:environment_id/secrets/:id") ==
               {:ok, {"DELETE", "/api/environments/:environment_id/secrets/:id"}}
    end

    test "refuses semantic context actions, which keep their own event names" do
      assert Analytics.api_request("agent.created") == :error
      assert Analytics.api_request("vault.secret.write") == :error
      assert Analytics.api_request("api_key.created") == :error
    end

    test "refuses anything that is not a request line" do
      assert Analytics.api_request("") == :error
      assert Analytics.api_request("POST") == :error
      assert Analytics.api_request("POSTED /api/things") == :error
      assert Analytics.api_request("POST api/things") == :error
      assert Analytics.api_request(nil) == :error
    end

    test "the two classifiers never both claim an action" do
      # `product_event?/2` names the event after the action; `api_request/1`
      # puts the action in a property. An action both accepted would be
      # captured twice under two different shapes.
      actions = [
        "agent.created",
        "vault.secret.write",
        "api_key.created",
        "POST /api/conversations",
        "GET /api/agents/:id",
        "PATCH /api/team/:agent_id"
      ]

      for action <- actions do
        refute Analytics.product_event?(action, "api") and
                 match?({:ok, _}, Analytics.api_request(action)),
               "#{action} was claimed by both classifiers"
      end
    end
  end
end
