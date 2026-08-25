defmodule Fountain.Broker.InjectorTest do
  use ExUnit.Case, async: true

  alias Fountain.Broker.Injector

  @binding %{
    credentials: %{
      "GITHUB_TOKEN" => "ghp_real",
      "GITHUB_BASIC_USER" => "x-access-token",
      "ANTHROPIC_API_KEY" => "sk-ant-real",
      "DISCORD_BOT_TOKEN" => "disc",
      "PAGERDUTY_TOKEN" => "pd"
    },
    services: [
      %{
        "name" => "github-api",
        "host" => "api.github.com",
        "auth" => %{"type" => "bearer", "token" => "GITHUB_TOKEN"}
      },
      %{
        "name" => "github-git",
        "host" => "github.com",
        "auth" => %{
          "type" => "basic",
          "username" => "GITHUB_BASIC_USER",
          "password" => "GITHUB_TOKEN"
        }
      },
      %{
        "name" => "anthropic",
        "host" => "api.anthropic.com",
        "auth" => %{"type" => "api-key", "header" => "x-api-key", "key" => "ANTHROPIC_API_KEY"}
      },
      %{
        "name" => "discord",
        "host" => "discord.com/api/*",
        "auth" => %{"type" => "api-key", "prefix" => "Bot ", "key" => "DISCORD_BOT_TOKEN"}
      },
      %{
        "name" => "pagerduty",
        "host" => "api.pagerduty.com",
        "auth" => %{
          "type" => "custom",
          "headers" => %{
            "Authorization" => "Token token={{ PAGERDUTY_TOKEN }}",
            "X-Missing" => "{{ NOT_A_KEY }}"
          }
        }
      }
    ],
    unmatched_host_policy: "passthrough"
  }

  @headers [
    {"Host", "api.github.com"},
    {"Proxy-Authorization", "Basic abc"},
    {"Authorization", "Bearer __github_token__"},
    {"Accept", "application/json"}
  ]

  defp inject(headers, host, path \\ "/"), do: Injector.inject(headers, host, 443, path, @binding)

  test "a bearer service replaces the authorization header wholesale" do
    assert {:ok, headers, "github-api"} = inject(@headers, "api.github.com")

    assert {"authorization", "Bearer ghp_real"} in headers
    refute Enum.any?(headers, fn {k, _} -> String.downcase(k) == "proxy-authorization" end)
    assert Enum.count(headers, fn {k, _} -> String.downcase(k) == "authorization" end) == 1
    assert {"Accept", "application/json"} in headers
  end

  test "a basic service encodes username and password from the credentials" do
    {:ok, headers, "github-git"} = inject(@headers, "github.com")
    assert {"authorization", "Basic " <> Base.encode64("x-access-token:ghp_real")} in headers
  end

  test "an api-key service writes its own header, and leaves authorization alone" do
    headers = [{"x-api-key", "__anthropic_api_key__"}, {"Authorization", "Bearer keep"}]
    {:ok, out, "anthropic"} = inject(headers, "api.anthropic.com")

    assert {"x-api-key", "sk-ant-real"} in out
    assert {"Authorization", "Bearer keep"} in out
    refute {"x-api-key", "__anthropic_api_key__"} in out
  end

  test "an api-key service with a prefix and no header writes Authorization with the prefix" do
    {:ok, out, "discord"} = inject(@headers, "discord.com", "/api/v10/users/@me")
    assert {"Authorization", "Bot disc"} in out
    refute {"Authorization", "Bearer __github_token__"} in out
  end

  test "a custom service renders every {{ KEY }} it holds and leaves one it does not" do
    {:ok, out, "pagerduty"} = inject(@headers, "api.pagerduty.com")
    assert {"Authorization", "Token token=pd"} in out
    assert {"X-Missing", "{{ NOT_A_KEY }}"} in out
  end

  test "an unmatched host passes through with only the hop-by-hop headers dropped" do
    {:ok, headers, nil} = inject(@headers, "example.com")

    assert {"Authorization", "Bearer __github_token__"} in headers
    refute Enum.any?(headers, fn {k, _} -> k == "Proxy-Authorization" end)
  end

  test "deny refuses an unmatched host" do
    binding = %{@binding | unmatched_host_policy: "deny"}
    assert {:error, :denied} = Injector.inject(@headers, "example.com", 443, "/", binding)
    assert {:ok, _, "github-api"} = Injector.inject(@headers, "api.github.com", 443, "/", binding)
  end

  test "the match is on the exact host: api.github.com is not github.com" do
    {:ok, _, "github-git"} = inject(@headers, "github.com")
    {:ok, _, nil} = inject(@headers, "gist.github.com")
  end

  describe "matches?/4" do
    test "host, case-insensitively, any port" do
      assert Injector.matches?("api.stripe.com", "API.Stripe.com", 443, "/v1")
      refute Injector.matches?("api.stripe.com", "stripe.com", 443, "/")
    end

    test "a wildcard host matches subdomains only" do
      assert Injector.matches?("*.atlassian.net", "acme.atlassian.net", 443, "/")
      refute Injector.matches?("*.atlassian.net", "atlassian.net", 443, "/")
    end

    test "a port pins the port" do
      assert Injector.matches?("db.example.com:8443", "db.example.com", 8443, "/")
      refute Injector.matches?("db.example.com:8443", "db.example.com", 443, "/")
    end

    test "a path is a prefix; a trailing * matches the rest; the query is ignored" do
      assert Injector.matches?("discord.com/api/*", "discord.com", 443, "/api/v10/x?y=1")
      refute Injector.matches?("discord.com/api/*", "discord.com", 443, "/oauth2")
      assert Injector.matches?("h.example/v1", "h.example", 443, "/v1")
      assert Injector.matches?("h.example/v1", "h.example", 443, "/v1/users")
      refute Injector.matches?("h.example/v1", "h.example", 443, "/v10")
    end
  end
end
