defmodule Fountain.Team.Comms.AgentMail do
  @moduledoc """
  Thin client for the AgentMail API (`api.agentmail.to/v0`) — the inboxes
  Fountain provisions for teammates and the messages in them.

  Fountain holds the key (`AGENTMAIL_API_KEY`); every call here runs
  server-side on a teammate's behalf. Responses come back as the decoded JSON
  maps the API returns; errors as `{:error, {:status, code, body}}` or
  `{:error, reason}` for a transport failure. Tests inject a `Req.Test` plug
  through `:agentmail_req_options`.
  """

  @doc "Whether an API key is configured."
  def configured?, do: is_binary(api_key()) and api_key() != ""

  def api_key, do: Application.get_env(:fountain, :agentmail_api_key)

  def base_url,
    do: Application.get_env(:fountain, :agentmail_base_url, "https://api.agentmail.to")

  @doc "The custom domain for teammate addresses, or nil for AgentMail's shared one."
  def domain do
    case Application.get_env(:fountain, :agentmail_domain) do
      d when is_binary(d) and d != "" -> d
      _ -> nil
    end
  end

  def req do
    Req.new(
      [
        base_url: base_url(),
        auth: {:bearer, api_key() || ""},
        receive_timeout: Application.get_env(:fountain, :agentmail_timeout_ms, 15_000),
        retry: false
      ] ++ Application.get_env(:fountain, :agentmail_req_options, [])
    )
  end

  @doc """
  Create an inbox. `attrs` may carry `username`, `domain`, `display_name`,
  `client_id`, `metadata`. Returns the inbox map (`inbox_id`, `email`, …).
  """
  def create_inbox(attrs) when is_map(attrs), do: post("/v0/inboxes", attrs)

  def delete_inbox(inbox_id), do: request(:delete, "/v0/inboxes/#{enc(inbox_id)}")

  def list_messages(inbox_id, params \\ []),
    do: request(:get, "/v0/inboxes/#{enc(inbox_id)}/messages", params: params)

  def get_message(inbox_id, message_id),
    do: request(:get, "/v0/inboxes/#{enc(inbox_id)}/messages/#{enc(message_id)}")

  def send_message(inbox_id, body) when is_map(body),
    do: post("/v0/inboxes/#{enc(inbox_id)}/messages/send", body)

  def reply_to_message(inbox_id, message_id, body) when is_map(body),
    do: post("/v0/inboxes/#{enc(inbox_id)}/messages/#{enc(message_id)}/reply", body)

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
