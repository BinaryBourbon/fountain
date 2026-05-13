defmodule Fountain.Conversations.TitleGenerator do
  @moduledoc """
  Generates a short title (≤50 chars) for a conversation's first prompt by
  calling an LLM API. Credential priority:
  claude_code_oauth_token → anthropic_api_key → openai_api_key → gemini_api_key
  """

  require Logger

  @max_chars 50

  @doc """
  Generate a short title for the given prompt using available credentials.
  Returns `{:ok, title}` or `{:error, reason}`.
  """
  @spec generate(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, credentials) when is_binary(prompt) and is_map(credentials) do
    cond do
      token = Map.get(credentials, :claude_code_oauth_token) ->
        call_anthropic(prompt, token, :oauth)

      key = Map.get(credentials, :anthropic_api_key) ->
        call_anthropic(prompt, key, :api_key)

      key = Map.get(credentials, :openai_api_key) ->
        call_openai(prompt, key)

      key = Map.get(credentials, :gemini_api_key) ->
        call_gemini(prompt, key)

      true ->
        {:error, :no_credentials}
    end
  end

  # ── providers ─────────────────────────────────────────────────────────────

  defp call_anthropic(prompt, credential, type) do
    auth_header =
      case type do
        :api_key -> {"x-api-key", credential}
        :oauth -> {"Authorization", "Bearer #{credential}"}
      end

    body = %{
      model: "claude-haiku-4-5",
      max_tokens: 30,
      system: system_prompt(),
      messages: [%{role: "user", content: String.slice(prompt, 0, 500)}]
    }

    case Req.post("https://api.anthropic.com/v1/messages",
           headers: [auth_header, {"anthropic-version", "2023-06-01"}],
           json: body,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, sanitize(text)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("TitleGenerator: Anthropic returned #{status}: #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp call_openai(prompt, api_key) do
    body = %{
      model: "gpt-4o-mini",
      max_tokens: 30,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: String.slice(prompt, 0, 500)}
      ]
    }

    case Req.post("https://api.openai.com/v1/chat/completions",
           headers: [{"Authorization", "Bearer #{api_key}"}],
           json: body,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, sanitize(text)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("TitleGenerator: OpenAI returned #{status}: #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp call_gemini(prompt, api_key) do
    url =
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=#{api_key}"

    body = %{
      contents: [
        %{
          role: "user",
          parts: [%{text: "#{system_prompt()}\n\n#{String.slice(prompt, 0, 500)}"}]
        }
      ],
      generationConfig: %{maxOutputTokens: 30}
    }

    case Req.post(url, json: body, receive_timeout: 10_000) do
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [
             %{"content" => %{"parts" => [%{"text" => text} | _]}} | _
           ]
         }
       }} ->
        {:ok, sanitize(text)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("TitleGenerator: Gemini returned #{status}: #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp system_prompt do
    "Generate a title of 3-7 words for the following task or prompt. " <>
      "Return ONLY the title, no quotes, no punctuation at the end."
  end

  defp sanitize(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A["']|["']\z/, "")
    |> String.split("\n")
    |> List.first("")
    |> String.trim()
    |> String.slice(0, @max_chars)
  end
end
