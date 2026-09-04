defmodule FountainWeb.Plugs.ExtensionDispatchTest do
  @moduledoc """
  The `/api/<prefix>` dispatch seam (ADR 0043, #1505).

  Everything goes through the real endpoint and the real router, because the
  properties under test are properties of the *mount* — that the `:api`
  pipeline ran, that core routes were tried first, that the prefix was trimmed
  — and none of them survives calling the plug directly.
  """
  use FountainWeb.ConnCase, async: true

  alias Fountain.ExtensionFixtures.Enabled

  setup do
    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)
    %{user: user, raw_key: raw_key}
  end

  describe "authentication" do
    test "an extension route is refused without a key", %{conn: conn} do
      conn = get(conn, "/api/fixture/whoami")

      assert json_response(conn, 401)["reason"] == "api_key_invalid"
    end

    test "an extension route is refused with a bad key", %{conn: conn} do
      conn =
        conn
        |> authed_with_key("ftn_not_a_real_key")
        |> get("/api/fixture/whoami")

      assert json_response(conn, 401)["reason"] == "api_key_invalid"
    end

    test "the extension sees the host's current_user, not one of its own", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/fixture/whoami")

      body = json_response(conn, 200)
      assert body["user_id"] == ctx.user.id
      assert body["email"] == ctx.user.email
    end

    test "a revoked key is refused before the extension is reached", ctx do
      {record, raw_key} = insert_api_key(ctx.user)
      {:ok, _} = Fountain.Accounts.revoke_api_key(ctx.user.id, record.id)

      conn =
        ctx.conn
        |> authed_with_key(raw_key)
        |> get("/api/fixture/whoami")

      assert json_response(conn, 401)["reason"] == "api_key_revoked"
    end
  end

  describe "path trimming" do
    test "the prefix moves from path_info to script_name", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/fixture/whoami")

      body = json_response(conn, 200)
      # The extension's router matched "/whoami", not "/api/fixture/whoami":
      # it writes its routes relative to its own mount and never repeats its
      # own prefix.
      assert body["path_info"] == ["whoami"]
      assert body["script_name"] == ["api", "fixture"]
    end

    test "a nested path keeps every segment after the prefix", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/fixture/nested/deep")

      assert json_response(conn, 200)["path_info"] == ["nested", "deep"]
    end
  end

  describe "core routes win" do
    test "a core route is served by core even though dispatch is mounted at /api", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/agents")

      # Not the extension's 404 body, and not the fixture's shape: the core
      # controller answered. Dispatch is declared last precisely so this holds.
      assert %{"data" => _} = json_response(conn, 200)
    end

    test "the public spec route is untouched", %{conn: conn} do
      # /api/openapi.json is unauthenticated and declared long before the
      # forward. If dispatch had been mounted earlier it would now demand a key.
      assert conn |> get("/api/openapi.json") |> json_response(200)
    end
  end

  describe "absent and disabled extensions" do
    test "an unknown prefix is 404, not 500", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/nothing-serves-this/at-all")

      assert json_response(conn, 404)["reason"] == "not_found"
    end

    test "a configured-but-disabled extension answers 404, not its own routes", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/fixture-disabled/whoami")

      # Byte-identical to the unknown-prefix answer above: whether this
      # deployment installed an optional integration is not a thing a 404
      # should disclose.
      assert json_response(conn, 404)["reason"] == "not_found"
    end

    test "a bare /api is 404 rather than crashing on an empty path", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api")

      assert json_response(conn, 404)["reason"] == "not_found"
    end

    test "an unknown path under a real prefix is the extension's own 404", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/fixture/nope")

      # Past the seam the extension owns its own error rendering: this is the
      # fixture router's NoRouteError rendered by its error view, not the
      # host's `{error, reason}` body. Worth pinning — it is how you tell
      # "dispatch found no extension" from "the extension found no route".
      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  describe "the seam does not need Buzz" do
    test "the fixture proves the whole contract with no extension app installed" do
      # #1505's gate in one assertion: the seam is exercised end to end by a
      # fixture, so #1507 can move Buzz onto it without the architecture being
      # decided by that PR.
      assert Enabled.api_prefix() == "fixture"
      assert Fountain.Extensions.find_by_prefix("fixture") == Enabled
      assert Enabled.conversation_mcp_servers(Enabled.claimed_conversation_id(), "t") != []
    end
  end
end
