defmodule Fountain.Conversations.TitleGeneratorTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Conversations.TitleGenerator

  describe "generate/2 with no credentials" do
    test "returns error when credentials map is empty" do
      assert {:error, :no_credentials} = TitleGenerator.generate("Fix login", %{})
    end
  end

  describe "generate/2 with anthropic_api_key" do
    test "calls Anthropic API and returns title" do
      Req
      |> expect(:post, fn "https://api.anthropic.com/v1/messages", opts ->
        assert Keyword.get(opts, :json)[:model] == "claude-haiku-4-5"
        assert {"x-api-key", "sk-test"} in Keyword.get(opts, :headers, [])
        {:ok, %{status: 200, body: %{"content" => [%{"text" => "Fix the Login Bug"}]}}}
      end)

      assert {:ok, "Fix the Login Bug"} =
               TitleGenerator.generate("Fix login bug in auth", %{anthropic_api_key: "sk-test"})
    end

    test "strips surrounding quotes from title" do
      Req
      |> stub(:post, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"content" => [%{"text" => "\"Debug Memory Leak\""}]}}}
      end)

      assert {:ok, "Debug Memory Leak"} =
               TitleGenerator.generate("debug memory leak", %{anthropic_api_key: "sk-test"})
    end

    test "takes only the first line" do
      Req
      |> stub(:post, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"content" => [%{"text" => "Fix Auth Bug\nExtra text"}]}}}
      end)

      assert {:ok, "Fix Auth Bug"} =
               TitleGenerator.generate("fix auth", %{anthropic_api_key: "sk-test"})
    end

    test "truncates to 50 characters" do
      long = String.duplicate("A", 60)

      Req
      |> stub(:post, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"content" => [%{"text" => long}]}}}
      end)

      {:ok, title} = TitleGenerator.generate("some prompt", %{anthropic_api_key: "sk-test"})
      assert String.length(title) == 50
    end

    test "returns error on non-200 response" do
      Req
      |> stub(:post, fn _url, _opts ->
        {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
      end)

      assert {:error, {:api_error, 401}} =
               TitleGenerator.generate("prompt", %{anthropic_api_key: "bad-key"})
    end

    test "returns error on request failure" do
      Req
      |> stub(:post, fn _url, _opts -> {:error, :timeout} end)

      assert {:error, {:request_failed, _}} =
               TitleGenerator.generate("prompt", %{anthropic_api_key: "sk-test"})
    end
  end

  describe "generate/2 credential priority" do
    test "prefers claude_code_oauth_token over anthropic_api_key" do
      Req
      |> expect(:post, fn _url, opts ->
        headers = Keyword.get(opts, :headers, [])
        assert Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
        refute Enum.any?(headers, fn {k, _} -> k == "x-api-key" end)
        {:ok, %{status: 200, body: %{"content" => [%{"text" => "Some Title"}]}}}
      end)

      assert {:ok, _} =
               TitleGenerator.generate("prompt", %{
                 claude_code_oauth_token: "oauth-token",
                 anthropic_api_key: "sk-test"
               })
    end
  end

  describe "generate/2 with openai_api_key" do
    test "calls OpenAI chat completions" do
      Req
      |> expect(:post, fn "https://api.openai.com/v1/chat/completions", opts ->
        assert Keyword.get(opts, :json)[:model] == "gpt-4o-mini"

        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => "Fix Auth Issue"}}]}
         }}
      end)

      assert {:ok, "Fix Auth Issue"} =
               TitleGenerator.generate("fix auth", %{openai_api_key: "sk-openai"})
    end
  end

  describe "generate/2 with gemini_api_key" do
    test "calls Gemini generateContent" do
      Req
      |> expect(:post, fn url, _opts ->
        assert String.starts_with?(url, "https://generativelanguage.googleapis.com")
        assert String.contains?(url, "gemini-key")

        {:ok,
         %{
           status: 200,
           body: %{
             "candidates" => [
               %{"content" => %{"parts" => [%{"text" => "Deploy New Feature"}]}}
             ]
           }
         }}
      end)

      assert {:ok, "Deploy New Feature"} =
               TitleGenerator.generate("deploy feature", %{gemini_api_key: "gemini-key"})
    end
  end
end
