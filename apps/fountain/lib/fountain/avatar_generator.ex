defmodule Fountain.AvatarGenerator do
  @moduledoc """
  Generate avatar images using OpenAI DALL-E 3.

  Accepts a character base (robot / human / alien) and mood
  (serious / casual / goofy), builds a prompt, calls the DALL-E 3
  image-generation API, and returns the raw PNG binary.

  Uses the user's stored OpenAI API key from `Fountain.InferenceCredentials`.
  Returns `{:error, :no_openai_key}` if none is configured.
  """

  alias Fountain.{Crypto, InferenceCredentials}

  @openai_url "https://api.openai.com/v1/images/generations"

  @base_descriptions %{
    "robot" => "a mechanical robot",
    "human" => "a human person",
    "alien" => "a friendly alien creature"
  }

  @mood_descriptions %{
    "serious" => "with a serious, professional expression",
    "casual" => "with a relaxed, friendly expression",
    "goofy" => "with a silly, humorous expression"
  }

  @doc "Valid base character types."
  def bases, do: ~w(robot human alien)

  @doc "Valid mood options."
  def moods, do: ~w(serious casual goofy)

  @doc """
  Generate a PNG avatar image for the given user.

  Returns `{:ok, png_binary}` or `{:error, reason}` where reason is
  `:no_openai_key`, `:not_found`, or a human-readable error string.
  """
  @spec generate(binary(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def generate(user_id, base, mood) do
    with {:ok, api_key} <- get_openai_key(user_id),
         prompt = build_prompt(base, mood),
         {:ok, data} <- call_openai(api_key, prompt) do
      {:ok, data}
    end
  end

  @doc "Build the DALL-E prompt for the given base and mood. Exported for testability."
  @spec build_prompt(String.t(), String.t()) :: String.t()
  def build_prompt(base, mood) do
    base_desc = Map.get(@base_descriptions, base, "a character")
    mood_desc = Map.get(@mood_descriptions, mood, "with a neutral expression")

    "A square profile avatar of #{base_desc} #{mood_desc}, " <>
      "simple solid color background, centered composition, " <>
      "digital illustration style, clean and vivid"
  end

  ## Private

  defp get_openai_key(user_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, creds} <- InferenceCredentials.decrypted_for_user(user_id, dek) do
      case Map.get(creds, :openai_api_key) do
        nil -> {:error, :no_openai_key}
        key -> {:ok, key}
      end
    end
  end

  defp call_openai(api_key, prompt) do
    body = %{
      model: "dall-e-3",
      prompt: prompt,
      n: 1,
      size: "1024x1024",
      response_format: "b64_json"
    }

    case Req.post(@openai_url,
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"data" => [%{"b64_json" => b64} | _]}}} ->
        {:ok, Base.decode64!(b64)}

      {:ok, %{status: _status, body: body}} ->
        msg = get_in(body, ["error", "message"]) || "Image generation failed"
        {:error, msg}

      {:error, exception} ->
        {:error, "Request failed: #{Exception.message(exception)}"}
    end
  end
end
