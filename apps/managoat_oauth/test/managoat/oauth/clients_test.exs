defmodule Managoat.OAuth.ClientsTest do
  use Managoat.OAuth.Case, async: true

  alias Managoat.OAuth.Clients

  describe "clients/0" do
    test "normalises atom- and string-keyed entries, name falling back to id" do
      assert [
               %{id: "test-app", name: "Test App", redirect_uris: [_, _]},
               %{id: "json-app", name: "json-app", redirect_uris: ["https://json.test:8443/cb"]}
             ] = TestInstance.clients()
    end

    test "get_client/1 finds by id and answers nil for anything else" do
      assert %{id: "json-app"} = TestInstance.get_client("json-app")
      assert TestInstance.get_client("nope") == nil
      assert TestInstance.get_client(nil) == nil
      assert TestInstance.get_client(42) == nil
    end

    test "normalize/1 accepts keyword entries and an empty list" do
      assert Clients.normalize([]) == []

      assert [%{id: "kw", name: "kw", redirect_uris: []}] =
               Clients.normalize([[id: :kw]])
    end
  end

  describe "redirect_origins/0" do
    test "is the distinct scheme://host[:port] of every redirect URI" do
      assert TestInstance.redirect_origins() == [
               "https://app.test",
               "http://localhost:5173",
               "https://json.test:8443"
             ]
    end

    test "skips a URI with no scheme or host" do
      assert Clients.redirect_origins([
               %{id: "x", name: "x", redirect_uris: ["not a uri", "https://ok.test/"]}
             ]) == ["https://ok.test"]
    end
  end

  describe "validate_request/1" do
    test "accepts a registered client, exact redirect and S256 challenge" do
      {_v, c} = pkce()
      assert {:ok, %{id: "test-app"}} = TestInstance.validate_request(request(c))
      # The method defaults to S256 when absent.
      assert {:ok, _} =
               TestInstance.validate_request(Map.delete(request(c), "code_challenge_method"))
    end

    test "refuses what must never redirect" do
      {_v, c} = pkce()

      assert {:error, :unknown_client} =
               TestInstance.validate_request(request(c, %{"client_id" => "nope"}))

      assert {:error, :redirect_uri_mismatch} =
               TestInstance.validate_request(
                 request(c, %{"redirect_uri" => "https://app.test/callback?x=1"})
               )

      assert {:error, :redirect_uri_mismatch} =
               TestInstance.validate_request(
                 request(c, %{"redirect_uri" => "https://evil.test/"})
               )

      assert {:error, :unsupported_code_challenge_method} =
               TestInstance.validate_request(request(c, %{"code_challenge_method" => "plain"}))

      assert {:error, :invalid_code_challenge} = TestInstance.validate_request(request("short"))
      assert {:error, :invalid_code_challenge} = TestInstance.validate_request(request(nil))
    end
  end
end
