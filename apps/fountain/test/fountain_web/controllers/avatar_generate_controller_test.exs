defmodule FountainWeb.AvatarGenerateControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.AvatarGenerator

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  test "returns the generated PNG as base64", %{conn: conn, user: user, raw_key: key} do
    user_id = user.id

    stub(AvatarGenerator, :generate, fn ^user_id, "robot", "goofy" ->
      {:ok, <<137, 80, 78, 71>>}
    end)

    body =
      conn
      |> authed_with_key(key)
      |> post_json("/api/avatars/generate", %{base: "robot", mood: "goofy"})
      |> json_response(200)

    assert body["data"]["media_type"] == "image/png"
    assert Base.decode64!(body["data"]["data"]) == <<137, 80, 78, 71>>
  end

  test "422 without an OpenAI credential; 502 when the provider refuses", %{
    conn: conn,
    raw_key: key
  } do
    stub(AvatarGenerator, :generate, fn _, _, _ -> {:error, :no_openai_key} end)

    assert %{"error" => "no_openai_key"} =
             conn
             |> authed_with_key(key)
             |> post_json("/api/avatars/generate", %{base: "robot", mood: "goofy"})
             |> json_response(422)

    stub(AvatarGenerator, :generate, fn _, _, _ -> {:error, "rate limited"} end)

    assert %{"error" => "avatar_generation_failed", "message" => "rate limited"} =
             conn
             |> authed_with_key(key)
             |> post_json("/api/avatars/generate", %{base: "robot", mood: "goofy"})
             |> json_response(502)
  end

  test "an unknown base or mood is refused before any call", %{conn: conn, raw_key: key} do
    reject(&AvatarGenerator.generate/3)

    resp =
      conn
      |> authed_with_key(key)
      |> post_json("/api/avatars/generate", %{base: "dragon", mood: "goofy"})

    assert resp.status == 400
    assert json_response(resp, 400)["error"] =~ "unknown base"
  end
end
