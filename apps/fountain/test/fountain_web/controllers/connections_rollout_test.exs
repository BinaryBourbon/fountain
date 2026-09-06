defmodule FountainWeb.ConnectionsRolloutTest do
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers
  import Phoenix.LiveViewTest

  setup do
    user = insert_verified_user()
    {_key, raw} = insert_api_key(user)
    enable_connections_for([user.id])
    {:ok, user: user, raw: raw}
  end

  for {broker, flag} <- [{true, false}, {false, true}, {false, false}] do
    test "every management route requires broker=#{broker} and flag=#{flag}", ctx do
      Application.put_env(
        :fountain,
        :broker_tenants,
        if(unquote(broker), do: [ctx.user.id], else: [])
      )

      Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => unquote(flag)})

      routes =
        FountainWeb.Router.__routes__()
        |> Enum.filter(
          &String.starts_with?(&1.path, [
            "/api/connections",
            "/api/connection-providers",
            "/api/secret-bindings"
          ])
        )

      assert length(routes) >= 15

      for route <- routes do
        path = Regex.replace(~r/:[a-z_]+/, route.path, Ecto.UUID.generate())

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer " <> ctx.raw)
          |> put_req_header("accept", "application/json")

        result = dispatch(conn, @endpoint, route.verb, path, %{})

        expected =
          if String.starts_with?(path, "/api/secret-bindings"),
            do: "brokerage_not_enabled",
            else: "connections_not_enabled"

        assert json_response(result, 404)["error"] == expected, "#{route.verb} #{path}"
      end
    end
  end

  test "brokering stays visible while Connections is off, and both on opens the surface", ctx do
    Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => false})
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.raw)

    assert %{"brokered" => true, "connections_enabled" => false} =
             conn |> get("/api/auth/me") |> json_response(200)

    Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => true})

    assert %{"brokered" => true, "connections_enabled" => true} =
             conn |> get("/api/auth/me") |> json_response(200)

    assert %{"data" => []} = conn |> get("/api/connections") |> json_response(200)
  end

  test "flag off hides navigation, redirects both pages and refuses the OAuth round trip", ctx do
    Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => false})
    conn = login_user(build_conn(), ctx.user)
    html = conn |> get("/account") |> html_response(200)
    refute html =~ "Credential bindings"
    refute html =~ "href=\"/account/connections\""

    for path <- ["/account/connections", "/account/bindings"] do
      assert {:error, {:live_redirect, %{to: "/account"}}} = live(conn, path)
    end

    for path <- ["/connections/google/start", "/connections/google/callback"] do
      assert conn |> get(path) |> redirected_to() == "/account"
    end
  end
end
