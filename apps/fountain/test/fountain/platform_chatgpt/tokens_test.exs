defmodule Fountain.PlatformChatGPT.TokensTest do
  use ExUnit.Case, async: true

  import Fountain.ChatGPTFixtures

  alias Fountain.PlatformChatGPT.Tokens

  test "decode_payload/1 reads an unsigned JWT and refuses anything else" do
    assert {:ok, %{"a" => 1}} = Tokens.decode_payload(jwt(%{"a" => 1}))
    assert Tokens.decode_payload("one.two") == :error
    assert Tokens.decode_payload("a.!!!.c") == :error

    assert Tokens.decode_payload("a." <> Base.url_encode64("[1]", padding: false) <> ".c") ==
             :error

    assert Tokens.decode_payload(nil) == :error
  end

  test "claims/1 reads what codex reads, and needs the account id" do
    assert {:ok,
            %{
              "account_id" => "acct_platform_1",
              "user_id" => "user_1",
              "plan_type" => "pro",
              "email" => "admin@example.com"
            }} = Tokens.claims(id_token())

    assert {:error, :invalid_id_token} = Tokens.claims(jwt(%{"email" => "x"}))
    assert {:error, :invalid_id_token} = Tokens.claims("")
  end

  test "expires_at/1 is the exp claim, or nil for an opaque token" do
    at = Tokens.expires_at(access_token(600))
    assert DateTime.diff(at, DateTime.utc_now(), :second) in 590..600
    assert Tokens.expires_at("wst_opaque") == nil
    assert Tokens.expires_at(jwt(%{"exp" => "soon"})) == nil
  end

  test "synthesize_id_token/1 round-trips through claims/1 without an email" do
    token =
      Tokens.synthesize_id_token(%{"account_id" => "a", "user_id" => "u", "plan_type" => "p"})

    # The header is `{"alg":"none"}`; spelled out so it does not read as a key.
    unsigned = Base.url_encode64(~s({"alg":"none"}), padding: false)
    assert String.starts_with?(token, unsigned <> ".")

    assert {:ok, %{"account_id" => "a", "user_id" => "u", "plan_type" => "p", "email" => nil}} =
             Tokens.claims(token)
  end

  test "parse_auth_json/1 accepts a ChatGPT login and names why it refuses the rest" do
    assert {:ok, %{refresh_token: "rt_original", id_token: id}} =
             Tokens.parse_auth_json(auth_json())

    assert is_binary(id)

    assert {:error, :not_a_chatgpt_login} =
             Tokens.parse_auth_json(auth_json(%{auth_mode: "apiKey"}))

    assert {:error, :not_a_chatgpt_login} =
             Tokens.parse_auth_json(auth_json(%{auth_mode: "chatgptAuthTokens"}))

    assert {:error, :no_refresh_token} = Tokens.parse_auth_json(auth_json(%{refresh_token: ""}))
    assert {:error, :invalid_auth_json} = Tokens.parse_auth_json(~s({"tokens": "nope"}))
    assert {:error, :invalid_auth_json} = Tokens.parse_auth_json(42)
  end

  test "parse_auth_json/1 requires explicit ChatGPT mode without disclosing file contents" do
    file = Jason.decode!(auth_json())

    for rejected <-
          [Map.delete(file, "auth_mode")] ++
            Enum.map(
              [nil, "", "apikey", "apiKey", "chatgptAuthTokens", "secret-mode", 1, %{}],
              fn mode ->
                Map.put(file, "auth_mode", mode)
              end
            ) do
      assert {:error, :not_a_chatgpt_login} =
               Tokens.parse_auth_json(Jason.encode!(rejected))
    end

    for malformed <- [
          "not json",
          "[]",
          "null",
          "{}",
          ~s({"auth_mode":"chatgpt","tokens":null}),
          ~s({"auth_mode":"apikey","OPENAI_API_KEY":"secret-api-key"})
        ] do
      assert {:error, :invalid_auth_json} = Tokens.parse_auth_json(malformed)
    end
  end
end
