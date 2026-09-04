defmodule FountainWeb.ClaimableUserControllerTest do
  @moduledoc """
  The claimable-principal API (ADR 0044, #1551).

  The context test owns the mechanism; this file owns the door — statuses,
  the scope gate, and the shapes an application branches on when it lost a
  response.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Principals
  alias Fountain.Repo
  alias Fountain.Principals.ClaimableUser

  setup do
    app = insert_verified_user()
    {_rec, key} = insert_api_key(app)
    {:ok, app: app, key: key}
  end

  defp open(conn, key, body \\ %{"application_id" => "paddock"}, headers \\ []) do
    conn =
      Enum.reduce(headers, authed_with_key(conn, key), fn {k, v}, c -> put_req_header(c, k, v) end)

    post_json(conn, "/api/claimable-users", body)
  end

  describe "POST /api/claimable-users" do
    test "opens a principal and returns both secrets once", ctx do
      body = json_response(open(ctx.conn, ctx.key), 201)["data"]

      assert body["status"] == "unclaimed"
      assert body["principal_id"]
      assert String.starts_with?(body["api_key"], "ftn_")
      assert body["claim_token"]
      assert body["expires_at"]
    end

    test "the returned key operates the principal's own resources", ctx do
      body = json_response(open(ctx.conn, ctx.key), 201)["data"]

      created =
        build_conn()
        |> authed_with_key(body["api_key"])
        |> post_json("/api/agents", %{
          "name" => "terminal-1",
          "runtime" => "claude",
          "model" => "anthropic/claude-sonnet-4-5"
        })
        |> json_response(201)

      # Built under the principal, not under the application that opened it.
      listed =
        build_conn()
        |> authed_with_key(body["api_key"])
        |> get("/api/agents")
        |> json_response(200)

      assert created["data"]["id"] in Enum.map(listed["data"], & &1["id"])

      assert build_conn()
             |> authed_with_key(ctx.key)
             |> get("/api/agents/#{created["data"]["id"]}")
             |> json_response(404)
    end

    test "the returned key reaches nothing that manages an account", ctx do
      body = json_response(open(ctx.conn, ctx.key), 201)["data"]
      key = body["api_key"]

      for {method, path} <- [
            {:post, "/api/auth/api-keys"},
            {:post, "/api/claimable-users"},
            {:get, "/api/connections"},
            {:get, "/api/account/inference-credentials"}
          ] do
        conn =
          case method do
            :post -> build_conn() |> authed_with_key(key) |> post_json(path, %{})
            :get -> build_conn() |> authed_with_key(key) |> get(path)
          end

        assert json_response(conn, 403)["reason"] == "insufficient_scope",
               "#{method} #{path} was not refused"
      end
    end

    test "application_id is required", ctx do
      assert json_response(open(ctx.conn, ctx.key, %{}), 400)["reason"] == "invalid_request"
    end

    test "the same Idempotency-Key returns one principal", ctx do
      first =
        json_response(
          open(ctx.conn, ctx.key, %{"application_id" => "p"}, [{"idempotency-key", "k1"}]),
          201
        )["data"]

      second =
        json_response(
          open(build_conn(), ctx.key, %{"application_id" => "p"}, [{"idempotency-key", "k1"}]),
          201
        )["data"]

      assert first["id"] == second["id"]
      assert first["principal_id"] == second["principal_id"]
      refute first["api_key"] == second["api_key"]
    end

    test "a sprite-scoped key cannot open one", ctx do
      {_rec, sprite} = insert_sprite_api_key(ctx.app)

      assert json_response(open(build_conn(), sprite), 403)["reason"] == "insufficient_scope"
    end
  end

  describe "GET /api/claimable-users/:id" do
    test "the application can reconcile a lost response", ctx do
      created = json_response(open(ctx.conn, ctx.key), 201)["data"]

      body =
        build_conn()
        |> authed_with_key(ctx.key)
        |> get("/api/claimable-users/#{created["id"]}")
        |> json_response(200)

      assert body["data"]["status"] == "unclaimed"
      assert body["data"]["principal_id"] == created["principal_id"]
      # The secrets are not readable a second time.
      refute Map.has_key?(body["data"], "api_key")
      refute Map.has_key?(body["data"], "claim_token")
    end

    test "another account reads 404 rather than 403", ctx do
      created = json_response(open(ctx.conn, ctx.key), 201)["data"]
      {_rec, other} = insert_api_key(insert_verified_user())

      build_conn()
      |> authed_with_key(other)
      |> get("/api/claimable-users/#{created["id"]}")
      |> json_response(404)
    end
  end

  describe "POST /api/claimable-users/:id/claim" do
    setup ctx do
      created = json_response(open(ctx.conn, ctx.key), 201)["data"]
      claimer = insert_verified_user()
      {_rec, claimer_key} = insert_api_key(claimer)
      {:ok, created: created, claimer: claimer, claimer_key: claimer_key}
    end

    test "claims the principal and returns a working credential", ctx do
      body =
        build_conn()
        |> authed_with_key(ctx.claimer_key)
        |> post_json("/api/claimable-users/#{ctx.created["id"]}/claim", %{
          "claim_token" => ctx.created["claim_token"]
        })
        |> json_response(200)

      assert body["data"]["status"] == "claimed"
      assert body["data"]["principal_id"] == ctx.created["principal_id"]
      assert body["data"]["user"]["id"] == ctx.claimer.id
      refute body["data"]["api_key"] == ctx.created["api_key"]

      # The anonymous credential is done; the new one continues the tenant.
      build_conn()
      |> authed_with_key(ctx.created["api_key"])
      |> get("/api/agents")
      |> json_response(401)

      build_conn()
      |> authed_with_key(body["data"]["api_key"])
      |> get("/api/agents")
      |> json_response(200)
    end

    test "a bad token is 403 and leaves the grant open", ctx do
      body =
        build_conn()
        |> authed_with_key(ctx.claimer_key)
        |> post_json("/api/claimable-users/#{ctx.created["id"]}/claim", %{
          "claim_token" => "wrong"
        })
        |> json_response(403)

      assert body["reason"] == "invalid_claim_token"
      assert Repo.get(ClaimableUser, ctx.created["id"]).status == "unclaimed"
    end

    test "a second claim is 409", ctx do
      claim = fn key ->
        build_conn()
        |> authed_with_key(key)
        |> post_json("/api/claimable-users/#{ctx.created["id"]}/claim", %{
          "claim_token" => ctx.created["claim_token"]
        })
      end

      json_response(claim.(ctx.claimer_key), 200)

      {_rec, other} = insert_api_key(insert_verified_user())
      assert json_response(claim.(other), 409)["reason"] == "already_claimed"
    end

    test "an expired grant is 410", ctx do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Repo.get(ClaimableUser, ctx.created["id"])
      |> Ecto.Changeset.change(expires_at: past)
      |> Repo.update!()

      body =
        build_conn()
        |> authed_with_key(ctx.claimer_key)
        |> post_json("/api/claimable-users/#{ctx.created["id"]}/claim", %{
          "claim_token" => ctx.created["claim_token"]
        })
        |> json_response(410)

      assert body["reason"] == "expired"
    end
  end

  describe "DELETE /api/claimable-users/:id" do
    test "releases the grant and revokes its credential", ctx do
      created = json_response(open(ctx.conn, ctx.key), 201)["data"]

      build_conn()
      |> authed_with_key(ctx.key)
      |> delete("/api/claimable-users/#{created["id"]}")
      |> response(204)

      assert Repo.get(ClaimableUser, created["id"]).status == "released"

      build_conn()
      |> authed_with_key(created["api_key"])
      |> get("/api/agents")
      |> json_response(401)
    end

    test "the account that claimed it cannot release it", ctx do
      created = json_response(open(ctx.conn, ctx.key), 201)["data"]
      claimer = insert_verified_user()
      {_rec, claimer_key} = insert_api_key(claimer)

      {:ok, _} = Principals.claim(created["id"], created["claim_token"], claimer)

      build_conn()
      |> authed_with_key(claimer_key)
      |> delete("/api/claimable-users/#{created["id"]}")
      |> json_response(404)
    end
  end
end
