defmodule Fountain.AvatarGeneratorTest do
  use Fountain.DataCase, async: true

  import Mimic

  alias Fountain.AvatarGenerator
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials

  @fake_user_id "00000000-0000-0000-0000-000000000001"
  @fake_dek :crypto.strong_rand_bytes(32)
  @fake_key "sk-test-key"
  # Minimal 4-byte PNG-like blob for testing; Base.encode64 output is what the
  # API returns in b64_json, and we just verify round-trip fidelity.
  @fake_png <<137, 80, 78, 71>>

  describe "build_prompt/2" do
    test "includes the base description" do
      assert AvatarGenerator.build_prompt("robot", "serious") =~ "robot"
      assert AvatarGenerator.build_prompt("human", "casual") =~ "human"
      assert AvatarGenerator.build_prompt("alien", "goofy") =~ "alien"
    end

    test "includes the mood description" do
      assert AvatarGenerator.build_prompt("robot", "serious") =~ "serious"
      assert AvatarGenerator.build_prompt("human", "casual") =~ "casual"
      assert AvatarGenerator.build_prompt("alien", "goofy") =~ "goofy"
    end

    test "falls back gracefully for unknown values" do
      prompt = AvatarGenerator.build_prompt("dinosaur", "confused")
      assert is_binary(prompt)
      assert String.length(prompt) > 10
    end
  end

  describe "generate/3" do
    test "returns the decoded PNG binary on success" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:ok, @fake_dek} end)

      stub(InferenceCredentials, :decrypted_for_user, fn _uid, _dek ->
        {:ok, %{openai_api_key: @fake_key}}
      end)

      stub(Req, :post, fn _url, _opts ->
        {:ok, %{status: 200, body: %{"data" => [%{"b64_json" => Base.encode64(@fake_png)}]}}}
      end)

      assert {:ok, data} = AvatarGenerator.generate(@fake_user_id, "robot", "serious")
      assert data == @fake_png
    end

    test "passes the correct authorization header" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:ok, @fake_dek} end)

      stub(InferenceCredentials, :decrypted_for_user, fn _uid, _dek ->
        {:ok, %{openai_api_key: @fake_key}}
      end)

      stub(Req, :post, fn _url, opts ->
        headers = Keyword.get(opts, :headers, [])
        assert {"authorization", "Bearer " <> @fake_key} in headers
        {:ok, %{status: 200, body: %{"data" => [%{"b64_json" => Base.encode64(@fake_png)}]}}}
      end)

      AvatarGenerator.generate(@fake_user_id, "human", "casual")
    end

    test "returns :no_openai_key when user has no OpenAI credential" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:ok, @fake_dek} end)

      stub(InferenceCredentials, :decrypted_for_user, fn _uid, _dek ->
        {:ok, %{}}
      end)

      assert {:error, :no_openai_key} =
               AvatarGenerator.generate(@fake_user_id, "human", "casual")
    end

    test "propagates crypto :not_found error" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:error, :not_found} end)

      assert {:error, :not_found} =
               AvatarGenerator.generate(@fake_user_id, "alien", "goofy")
    end

    test "returns the API error message on non-200 response" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:ok, @fake_dek} end)

      stub(InferenceCredentials, :decrypted_for_user, fn _uid, _dek ->
        {:ok, %{openai_api_key: @fake_key}}
      end)

      stub(Req, :post, fn _url, _opts ->
        {:ok, %{status: 400, body: %{"error" => %{"message" => "Invalid prompt"}}}}
      end)

      assert {:error, "Invalid prompt"} =
               AvatarGenerator.generate(@fake_user_id, "robot", "serious")
    end

    test "falls back to generic message when API error has no message" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:ok, @fake_dek} end)

      stub(InferenceCredentials, :decrypted_for_user, fn _uid, _dek ->
        {:ok, %{openai_api_key: @fake_key}}
      end)

      stub(Req, :post, fn _url, _opts ->
        {:ok, %{status: 500, body: %{}}}
      end)

      assert {:error, "Image generation failed"} =
               AvatarGenerator.generate(@fake_user_id, "robot", "goofy")
    end

    test "returns an error string on network failure" do
      stub(Crypto, :load_tenant_key, fn _uid -> {:ok, @fake_dek} end)

      stub(InferenceCredentials, :decrypted_for_user, fn _uid, _dek ->
        {:ok, %{openai_api_key: @fake_key}}
      end)

      stub(Req, :post, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, error} = AvatarGenerator.generate(@fake_user_id, "robot", "serious")
      assert is_binary(error)
    end
  end
end
