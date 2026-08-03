defmodule FountainWeb.SentryScrubberTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.SentryScrubber

  # Regression tests for #402: Sentry's default body scrubber is an exact-name
  # denylist ("password", "passwd", "secret"), so the secret-write endpoints'
  # "value" field and the manifest apply's "secrets" map reached Sentry as
  # plaintext whenever an exception fired mid-request.

  describe "scrub_body/1 (unit)" do
    test "replaces every string value with a length tag, keeping shape" do
      conn = %Plug.Conn{params: %{"key" => "GITHUB_TOKEN", "value" => "ghp_plaintext"}}

      assert SentryScrubber.scrub_body(conn) == %{
               "key" => "[string:12]",
               "value" => "[string:13]"
             }
    end

    test "recurses through the manifest-apply shape" do
      conn = %Plug.Conn{
        params: %{
          "resources" => [
            %{
              "kind" => "Environment",
              "spec" => %{"secrets" => %{"ANTHROPIC_API_KEY" => "sk-ant-plaintext"}}
            }
          ]
        }
      }

      assert SentryScrubber.scrub_body(conn) == %{
               "resources" => [
                 %{
                   "kind" => "[string:11]",
                   "spec" => %{"secrets" => %{"ANTHROPIC_API_KEY" => "[string:16]"}}
                 }
               ]
             }
    end

    test "passes numbers, booleans and nil; tags uploads and structs" do
      conn = %Plug.Conn{
        params: %{
          "count" => 3,
          "flag" => true,
          "nothing" => nil,
          "file" => %Plug.Upload{filename: "a.txt"},
          "when" => ~U[2026-08-03 00:00:00Z]
        }
      }

      assert SentryScrubber.scrub_body(conn) == %{
               "count" => 3,
               "flag" => true,
               "nothing" => nil,
               "file" => "[upload:a.txt]",
               "when" => "[struct]"
             }
    end

    test "returns an empty map for unfetched params" do
      assert SentryScrubber.scrub_body(%Plug.Conn{}) == %{}
    end
  end

  describe "endpoint wiring (end to end)" do
    # Phoenix.ConnTest dispatches in the test process, so the request context
    # Sentry.PlugContext stored during the request is readable right here —
    # the same data an exception mid-request would ship.
    setup do
      on_exit(fn -> Sentry.Context.clear_all() end)

      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)
      {:ok, user: user, raw_key: raw_key}
    end

    test "a secret write leaves no plaintext in the Sentry request context",
         %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)
      plaintext = "plaintext-sentry-sentinel-51c2"

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/environments/#{env.id}/secrets", %{
          "key" => "SENTRY_PROBE",
          "value" => plaintext
        })

      assert conn.status in [200, 201]

      request_context = Sentry.Context.get_all().request
      rendered = inspect(request_context, limit: :infinity, printable_limit: :infinity)

      refute rendered =~ plaintext
      # The shape survives — this is what makes the allowlist debuggable.
      assert get_in(request_context, [:data, "value"]) == "[string:30]"
    end
  end
end
