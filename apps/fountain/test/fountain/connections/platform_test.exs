defmodule Fountain.Connections.PlatformTest do
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "lists every platform provider, configured or not, in catalog order" do
      assert [
               %Provider{slug: "google", user_id: nil, id: "google"},
               %Provider{slug: "microsoft", user_id: nil, id: "microsoft"},
               %Provider{slug: "slack", user_id: nil, id: "slack"}
             ] = Platform.all()

      assert Platform.slugs() == ~w(google microsoft slack)
      assert Provider.reserved_slugs() == Platform.slugs()
    end

    test "get/1 answers a platform slug and nothing else" do
      assert %Provider{slug: "microsoft"} = Platform.get("microsoft")
      assert Platform.get("github") == nil
      assert Platform.get(Ecto.UUID.generate()) == nil
    end

    test "every provider is a valid oauth2 record the shared client can drive" do
      for p <- Platform.all() do
        assert p.kind == "oauth2"
        assert Provider.platform?(p)
        assert p.authorize_url =~ "https://"
        assert p.token_url =~ "https://"
        assert p.env_key =~ ~r/^[A-Z_]+_ACCESS_TOKEN$/
        assert p.token_hosts != []
        # config/test.exs sets all three client id/secret pairs
        assert OAuth.configured?(p)
      end
    end

    test "names the config env var and the short name the console shows" do
      assert Platform.client_env_var(Platform.get("slack")) == "SLACK_OAUTH_CLIENT_ID"
      assert Platform.client_env_var(Platform.get("microsoft")) == "MICROSOFT_OAUTH_CLIENT_ID"
      assert Platform.short_name(Platform.get("google")) == "Google"
      assert Platform.short_name(Platform.get("microsoft")) == "Microsoft"
    end

    test "google asks for gmail and calendar; microsoft keeps offline_access" do
      assert "https://www.googleapis.com/auth/calendar" in Platform.get("google").scopes
      assert "https://www.googleapis.com/auth/gmail.modify" in Platform.get("google").scopes
      assert "offline_access" in Platform.get("microsoft").scopes
      # calendar/v3 lives on www.googleapis.com, which the broker binding covers
      assert "www.googleapis.com" in Platform.get("google").token_hosts
    end

    test "a tenant cannot take a platform slug" do
      user = insert_verified_user()

      for slug <- Platform.slugs() do
        assert {:error, cs} =
                 Connections.create_provider(user.id, provider_attrs(%{"slug" => slug}))

        assert "is a platform provider" in errors_on(cs).slug
      end
    end
  end

  describe "authorize_params/1" do
    test "google sends the offline pair with incremental consent" do
      assert %{
               "access_type" => "offline",
               "prompt" => "consent",
               "include_granted_scopes" => "true"
             } = Platform.authorize_params(Platform.get("google"))
    end

    test "microsoft asks for an account picker" do
      assert Platform.authorize_params(Platform.get("microsoft")) == %{
               "prompt" => "select_account"
             }
    end

    test "slack moves the request to user_scope and empties scope" do
      slack = Platform.get("slack")
      params = Platform.authorize_params(slack)

      assert params["scope"] == ""
      assert params["user_scope"] == Enum.join(slack.scopes, " ")

      # and the composed authorize URL carries that override
      url = OAuth.authorize_url(slack, "https://f.example/cb", "state123")
      query = URI.decode_query(URI.parse(url).query)
      assert query["scope"] == ""
      assert query["user_scope"] =~ "chat:write"
    end

    test "a tenant provider gets no extra parameters" do
      user = insert_verified_user()
      p = insert_provider(user)
      assert Platform.authorize_params(p) == %{}
    end
  end

  describe "normalize_token_body/2" do
    test "lifts slack's authed_user token to the top level" do
      body = %{
        "ok" => true,
        "app_id" => "A1",
        "authed_user" => %{
          "id" => "U1",
          "access_token" => "xoxp-1",
          "scope" => "channels:history,chat:write",
          "token_type" => "user"
        }
      }

      normalized = Platform.normalize_token_body(Platform.get("slack"), body)
      assert normalized["access_token"] == "xoxp-1"
      assert normalized["scope"] == "channels:history,chat:write"
      refute Map.has_key?(normalized, "refresh_token")
    end

    test "leaves every other provider's body alone" do
      body = %{"access_token" => "a", "authed_user" => %{"access_token" => "b"}}
      assert Platform.normalize_token_body(Platform.get("google"), body) == body

      user = insert_verified_user()
      p = insert_provider(user)
      assert Platform.normalize_token_body(p, body) == body
    end
  end
end
