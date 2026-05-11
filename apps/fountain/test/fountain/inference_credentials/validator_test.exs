defmodule Fountain.InferenceCredentials.ValidatorTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.InferenceCredentials.Validator

  describe "validate/2 - empty guard" do
    test "returns :empty for empty string with :anthropic_api_key" do
      assert {:error, :empty} = Validator.validate(:anthropic_api_key, "")
    end

    test "returns :empty for nil with :anthropic_api_key" do
      assert {:error, :empty} = Validator.validate(:anthropic_api_key, nil)
    end

    test "returns :empty for empty string with :claude_code_oauth_token" do
      assert {:error, :empty} = Validator.validate(:claude_code_oauth_token, "")
    end

    test "returns :empty for nil with :claude_code_oauth_token" do
      assert {:error, :empty} = Validator.validate(:claude_code_oauth_token, nil)
    end

    test "returns :empty for empty string with :openai_api_key" do
      assert {:error, :empty} = Validator.validate(:openai_api_key, "")
    end

    test "returns :empty for nil with :openai_api_key" do
      assert {:error, :empty} = Validator.validate(:openai_api_key, nil)
    end

    test "returns :empty for empty string with :gemini_api_key" do
      assert {:error, :empty} = Validator.validate(:gemini_api_key, "")
    end

    test "returns :empty for nil with :gemini_api_key" do
      assert {:error, :empty} = Validator.validate(:gemini_api_key, nil)
    end

    test "does not call Req.get for empty string" do
      reject(Req, :get, 2)
      assert {:error, :empty} = Validator.validate(:anthropic_api_key, "")
    end

    test "does not call Req.get for nil" do
      reject(Req, :get, 2)
      assert {:error, :empty} = Validator.validate(:openai_api_key, nil)
    end
  end

  describe "validate/2 - :ok on 200" do
    test "anthropic_api_key: returns :ok on 200" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      assert :ok = Validator.validate(:anthropic_api_key, "sk-ant-test")
    end

    test "claude_code_oauth_token: returns :ok on 200" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      assert :ok = Validator.validate(:claude_code_oauth_token, "oauth-token-test")
    end

    test "openai_api_key: returns :ok on 200" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      assert :ok = Validator.validate(:openai_api_key, "sk-openai-test")
    end

    test "gemini_api_key: returns :ok on 200" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      assert :ok = Validator.validate(:gemini_api_key, "gemini-key-test")
    end

    test "returns :ok on any 2xx status (204)" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 204}} end)
      assert :ok = Validator.validate(:anthropic_api_key, "sk-ant-test")
    end

    test "returns :ok on any 2xx status (299)" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 299}} end)
      assert :ok = Validator.validate(:openai_api_key, "sk-openai-test")
    end
  end

  describe "validate/2 - correct URL and headers" do
    test "anthropic_api_key sends request to Anthropic API with x-api-key header" do
      stub(Req, :get, fn url, opts ->
        assert url == "https://api.anthropic.com/v1/models"
        headers = Keyword.get(opts, :headers, [])
        assert {"x-api-key", "sk-ant-test"} in headers
        assert {"anthropic-version", "2023-06-01"} in headers
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = Validator.validate(:anthropic_api_key, "sk-ant-test")
    end

    test "claude_code_oauth_token sends request to Anthropic API with Bearer token" do
      stub(Req, :get, fn url, opts ->
        assert url == "https://api.anthropic.com/v1/models"
        headers = Keyword.get(opts, :headers, [])
        assert {"authorization", "Bearer oauth-token-test"} in headers
        assert {"anthropic-version", "2023-06-01"} in headers
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = Validator.validate(:claude_code_oauth_token, "oauth-token-test")
    end

    test "openai_api_key sends request to OpenAI API with Bearer token" do
      stub(Req, :get, fn url, opts ->
        assert url == "https://api.openai.com/v1/models"
        headers = Keyword.get(opts, :headers, [])
        assert {"authorization", "Bearer sk-openai-test"} in headers
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = Validator.validate(:openai_api_key, "sk-openai-test")
    end

    test "gemini_api_key sends request to Google API with key as query param" do
      stub(Req, :get, fn url, _opts ->
        assert String.starts_with?(url, "https://generativelanguage.googleapis.com/v1beta/models?key=")
        assert String.contains?(url, "gemini-key-test")
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = Validator.validate(:gemini_api_key, "gemini-key-test")
    end
  end

  describe "validate/2 - {:error, :invalid} on non-2xx" do
    test "returns {:error, :invalid, %{status: 401}} on 401" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 401}} end)
      assert {:error, :invalid, %{status: 401}} = Validator.validate(:anthropic_api_key, "bad-key")
    end

    test "returns {:error, :invalid, %{status: 403}} on 403" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 403}} end)
      assert {:error, :invalid, %{status: 403}} = Validator.validate(:openai_api_key, "bad-key")
    end

    test "returns {:error, :invalid, %{status: 429}} on 429" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 429}} end)
      assert {:error, :invalid, %{status: 429}} = Validator.validate(:claude_code_oauth_token, "token")
    end

    test "returns {:error, :invalid, %{status: 500}} on 500" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 500}} end)
      assert {:error, :invalid, %{status: 500}} = Validator.validate(:gemini_api_key, "key")
    end

    test "returns {:error, :invalid, %{status: 404}} on 404" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 404}} end)
      assert {:error, :invalid, %{status: 404}} = Validator.validate(:anthropic_api_key, "key")
    end

    test "returns {:error, :invalid} with the exact status code in the map" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 422}} end)
      assert {:error, :invalid, %{status: 422}} = Validator.validate(:openai_api_key, "key")
    end
  end

  describe "validate/2 - {:error, :timeout}" do
    test "returns {:error, :timeout} when Req returns timeout reason" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :timeout}} end)
      assert {:error, :timeout} = Validator.validate(:anthropic_api_key, "sk-ant-test")
    end

    test "returns {:error, :timeout} for openai_api_key on timeout" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :timeout}} end)
      assert {:error, :timeout} = Validator.validate(:openai_api_key, "sk-openai-test")
    end

    test "returns {:error, :timeout} for gemini_api_key on timeout" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :timeout}} end)
      assert {:error, :timeout} = Validator.validate(:gemini_api_key, "gemini-key")
    end
  end

  describe "validate/2 - {:error, :network}" do
    test "returns {:error, :network} on :econnrefused" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :econnrefused}} end)
      assert {:error, :network} = Validator.validate(:anthropic_api_key, "sk-ant-test")
    end

    test "returns {:error, :network} on :nxdomain" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :nxdomain}} end)
      assert {:error, :network} = Validator.validate(:openai_api_key, "sk-openai-test")
    end

    test "returns {:error, :network} on :closed" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :closed}} end)
      assert {:error, :network} = Validator.validate(:claude_code_oauth_token, "token")
    end

    test "returns {:error, :network} for gemini_api_key on connection error" do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :econnrefused}} end)
      assert {:error, :network} = Validator.validate(:gemini_api_key, "gemini-key")
    end
  end

  describe "validate/2 - Gemini URL encoding" do
    test "URL-encodes a key containing '+'" do
      stub(Req, :get, fn url, _opts ->
        assert String.contains?(url, URI.encode("+"))
        refute String.contains?(url, "key=+")
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = Validator.validate(:gemini_api_key, "key+with+plus")
    end

    test "URL-encodes a key containing '='" do
      stub(Req, :get, fn url, _opts ->
        assert String.contains?(url, URI.encode("="))
        {:ok, %Req.Response{status: 200}}
      end)

      assert :ok = Validator.validate(:gemini_api_key, "key=with=equals")
    end

    test "does not crash with a key containing special chars '+' and '='" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      assert :ok = Validator.validate(:gemini_api_key, "AIzaSy+abc/def==")
    end

    test "does not crash with a key containing spaces and slashes" do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)
      assert :ok = Validator.validate(:gemini_api_key, "key with spaces/and/slashes")
    end
  end
end
