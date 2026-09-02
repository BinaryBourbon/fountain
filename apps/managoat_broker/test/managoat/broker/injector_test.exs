defmodule Managoat.Broker.InjectorTest do
  use ExUnit.Case, async: true

  alias Managoat.Broker.{Injector, Rule, Session}

  @session %Session{
    rules: [
      %Rule{
        name: "github-api",
        pattern: "api.github.com",
        scheme: :bearer,
        credential: "ghp_real"
      },
      %Rule{
        name: "github-git",
        pattern: "github.com",
        scheme: :basic,
        credential: {"x-access-token", "ghp_real"}
      },
      %Rule{
        name: "anthropic",
        pattern: "api.anthropic.com",
        scheme: :api_key,
        header: "x-api-key",
        credential: "sk-ant-real"
      },
      %Rule{
        name: "discord",
        pattern: "discord.com/api/*",
        scheme: :api_key,
        prefix: "Bot ",
        credential: "disc"
      },
      %Rule{
        name: "pagerduty",
        pattern: "api.pagerduty.com",
        scheme: :custom,
        template: %{
          "Authorization" => "Token token={{ PAGERDUTY_TOKEN }}",
          "X-Missing" => "{{ NOT_A_KEY }}"
        },
        credential: %{"PAGERDUTY_TOKEN" => "pd"}
      },
      %Rule{
        name: "openai-sub",
        pattern: "api.openai.com",
        scheme: :substitute,
        placeholder: "sk-__openai_api_key__",
        credential: "sk-real-openai"
      },
      %Rule{
        name: "allowed",
        pattern: "registry.npmjs.org",
        scheme: :passthrough
      }
    ],
    unmatched_host_policy: :passthrough
  }

  @headers [
    {"Host", "api.github.com"},
    {"Proxy-Authorization", "Basic abc"},
    {"Authorization", "Bearer __github_token__"},
    {"Accept", "application/json"}
  ]

  defp inject(headers, host, path \\ "/", session \\ @session),
    do: Injector.inject(headers, host, 443, path, session)

  test "a bearer rule replaces the authorization header wholesale" do
    assert {:ok, headers, "github-api"} = inject(@headers, "api.github.com")

    assert {"authorization", "Bearer ghp_real"} in headers
    refute Enum.any?(headers, fn {k, _} -> String.downcase(k) == "proxy-authorization" end)
    assert Enum.count(headers, fn {k, _} -> String.downcase(k) == "authorization" end) == 1
    assert {"Accept", "application/json"} in headers
  end

  test "a basic rule encodes username and password" do
    {:ok, headers, "github-git"} = inject(@headers, "github.com")
    assert {"authorization", "Basic " <> Base.encode64("x-access-token:ghp_real")} in headers
  end

  test "an api-key rule writes its own header, and leaves authorization alone" do
    headers = [{"x-api-key", "__anthropic_api_key__"}, {"Authorization", "Bearer keep"}]
    {:ok, out, "anthropic"} = inject(headers, "api.anthropic.com")

    assert {"x-api-key", "sk-ant-real"} in out
    assert {"Authorization", "Bearer keep"} in out
    refute {"x-api-key", "__anthropic_api_key__"} in out
  end

  test "an api-key rule with a prefix and no header writes Authorization with the prefix" do
    {:ok, out, "discord"} = inject(@headers, "discord.com", "/api/v10/users/@me")
    assert {"Authorization", "Bot disc"} in out
    refute {"Authorization", "Bearer __github_token__"} in out
  end

  test "a custom rule renders every {{ KEY }} it holds and leaves one it does not" do
    {:ok, out, "pagerduty"} = inject(@headers, "api.pagerduty.com")
    assert {"Authorization", "Token token=pd"} in out
    assert {"X-Missing", "{{ NOT_A_KEY }}"} in out
  end

  test "a substitute rule replaces the placeholder wherever a header value carries it" do
    headers = [
      {"Host", "api.openai.com"},
      {"Authorization", "Bearer sk-__openai_api_key__"},
      {"X-Also", "prefix sk-__openai_api_key__ suffix"},
      {"X-Other", "untouched"}
    ]

    {:ok, out, "openai-sub"} = inject(headers, "api.openai.com")
    assert {"Authorization", "Bearer sk-real-openai"} in out
    assert {"X-Also", "prefix sk-real-openai suffix"} in out
    assert {"X-Other", "untouched"} in out
  end

  test "a substitute rule and a header rule on one host both apply; the first names the outcome" do
    session = %Session{
      rules: [
        %Rule{
          name: "sub",
          pattern: "api.anthropic.com",
          scheme: :substitute,
          placeholder: "__oauth__",
          credential: "oauth-real"
        },
        %Rule{
          name: "key",
          pattern: "api.anthropic.com",
          scheme: :api_key,
          header: "x-api-key",
          credential: "sk-real"
        }
      ]
    }

    headers = [{"Authorization", "Bearer __oauth__"}, {"x-api-key", "__key__"}]
    {:ok, out, "sub"} = inject(headers, "api.anthropic.com", "/v1/messages", session)
    assert {"Authorization", "Bearer oauth-real"} in out
    assert {"x-api-key", "sk-real"} in out
  end

  test "a passthrough rule forwards the request untouched but for the hop-by-hop headers" do
    {:ok, out, "allowed"} = inject(@headers, "registry.npmjs.org")
    assert {"Authorization", "Bearer __github_token__"} in out
    refute Enum.any?(out, fn {k, _} -> k == "Proxy-Authorization" end)
  end

  test "an unmatched host passes through with only the hop-by-hop headers dropped" do
    {:ok, headers, nil} = inject(@headers, "example.com")

    assert {"Authorization", "Bearer __github_token__"} in headers
    refute Enum.any?(headers, fn {k, _} -> k == "Proxy-Authorization" end)
  end

  test "deny refuses an unmatched host and lets a passthrough rule allow one" do
    session = %{@session | unmatched_host_policy: :deny}
    assert {:error, :denied} = inject(@headers, "example.com", "/", session)
    assert {:ok, _, "github-api"} = inject(@headers, "api.github.com", "/", session)
    assert {:ok, _, "allowed"} = inject(@headers, "registry.npmjs.org", "/", session)
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

  test "host_matches?/3 ignores the path part of the pattern" do
    assert Injector.host_matches?("discord.com/api/*", "discord.com", 443)
    refute Injector.host_matches?("discord.com:8443/api/*", "discord.com", 443)
    refute Injector.host_matches?("api.example.com", "example.com", 443)
  end
end
