defmodule FountainWeb.Plugs.CastRenderErrorTest do
  @moduledoc """
  The 422 body a request rejected by the OpenAPI cast comes back with (#1431).

  Two halves, and both matter. The unit tests pin the field mapping, which is
  the part a client reads. The request test pins that a real rejection actually
  goes through this renderer — the plug is wired into 25 controllers, and a
  correct renderer nobody installed would be invisible.
  """

  use FountainWeb.ConnCase, async: true

  alias FountainWeb.Plugs.CastRenderError
  alias OpenApiSpex.Cast.Error

  describe "the body" do
    test "carries the code and the field errors" do
      body = render([error(:invalid_type, [:limit], type: :integer, value: "not a number")])

      assert %{"error" => "validation_failed", "errors" => %{"limit" => [message]}} = body
      assert message =~ "Invalid integer"
    end

    test "carries both keys so it satisfies Error, AuthError and ChangesetError alike" do
      # The reason this renderer emits two keys rather than one: the 27
      # operations it answers for do not all declare the same 422 schema, and
      # none of those schemas forbids the other's key.
      body = render([error(:invalid_type, [:name], type: :string, value: 1)])

      assert Map.has_key?(body, "error"), "Error and AuthError require `error`"
      assert Map.has_key?(body, "errors"), "ChangesetError requires `errors`"
    end

    test "groups several failures on one field into one list, in order" do
      body =
        render([
          error(:invalid_type, [:cron], type: :string, value: 1),
          error(:invalid_format, [:cron], format: :cron, value: "nope")
        ])

      assert %{"errors" => %{"cron" => [_first, _second]}} = body
    end

    test "flattens a nested path, because the schema declares arrays of strings" do
      body = render([error(:invalid_type, [:repos, 0, :url], type: :string, value: 1)])

      assert %{"errors" => %{"repos/0/url" => [_]}} = body
    end

    test "files an error with no path under `body`" do
      body = render([error(:missing_field, [], name: :prompt)])

      assert %{"errors" => %{"body" => [_]}} = body
    end

    test "accepts a bare error as well as a list" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> CastRenderError.call(error(:invalid_type, [:limit], type: :integer, value: "x"))

      assert conn.status == 422
      assert %{"errors" => %{"limit" => [_]}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "through a real request" do
    setup do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      %{user: user, raw_key: raw_key}
    end

    test "a value the operation refuses is rendered by this plug, not by the default", ctx do
      # `category` is an enum in the spec, so CastAndValidate rejects this
      # before SupportReportController ever runs. Before #1431 the body was
      # `{"errors": [{"title": …, "source": {"pointer": "/category"}}]}` — an
      # array keyed by pointer, which no declared schema described and which
      # every SDK's `fieldErrors` read as empty.
      body =
        build_conn()
        |> authed_with_key(ctx.raw_key)
        |> post_json("/api/support/reports", %{"category" => "rant", "message" => "x"})
        |> json_response(422)

      assert %{"error" => "validation_failed", "errors" => %{"category" => [message]}} = body
      assert is_binary(message)
    end
  end

  defp render(errors) do
    Phoenix.ConnTest.build_conn()
    |> CastRenderError.call(errors)
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp error(reason, path, attrs) do
    %Error{reason: reason, path: path}
    |> struct(attrs)
  end
end
