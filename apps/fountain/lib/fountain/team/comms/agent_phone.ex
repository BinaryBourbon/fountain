defmodule Fountain.Team.Comms.AgentPhone do
  @moduledoc """
  Thin client for the AgentPhone API (`api.agentphone.ai/v1`) — the numbers
  Fountain provisions for teammates and the SMS on them.

  Fountain holds the key (`AGENTPHONE_API_KEY`); every call here runs
  server-side on a teammate's behalf. Same conventions as
  `Fountain.Team.Comms.AgentMail`; tests inject a `Req.Test` plug through
  `:agentphone_req_options`.
  """

  @doc "Whether an API key is configured."
  def configured?, do: is_binary(api_key()) and api_key() != ""

  def api_key, do: Application.get_env(:fountain, :agentphone_api_key)

  def base_url,
    do: Application.get_env(:fountain, :agentphone_base_url, "https://api.agentphone.ai")

  def req do
    Req.new(
      [
        base_url: base_url(),
        auth: {:bearer, api_key() || ""},
        receive_timeout: Application.get_env(:fountain, :agentphone_timeout_ms, 30_000),
        retry: false
      ] ++ Application.get_env(:fountain, :agentphone_req_options, [])
    )
  end

  @doc """
  Provision a number. `attrs` may carry `country` (default US), `areaCode`.
  Returns the number map (`id`, `phoneNumber`, `status`, `outboundSms`, …).
  """
  def create_number(attrs \\ %{}) when is_map(attrs), do: post("/v1/numbers", attrs)

  def delete_number(number_id), do: request(:delete, "/v1/numbers/#{enc(number_id)}")

  def list_messages(number_id, params \\ []),
    do: request(:get, "/v1/numbers/#{enc(number_id)}/messages", params: params)

  @doc "Send an SMS: `%{number_id:, to_number:, body:}`."
  def send_message(body) when is_map(body), do: post("/v1/messages", body)

  defp post(path, body), do: request(:post, path, json: body)

  defp request(method, path, opts \\ []) do
    case Req.request(req(), [method: method, url: path] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enc(s), do: URI.encode(to_string(s), &URI.char_unreserved?/1)
end
