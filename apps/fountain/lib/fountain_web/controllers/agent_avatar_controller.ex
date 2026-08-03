defmodule FountainWeb.AgentAvatarController do
  @moduledoc false
  use FountainWeb, :controller

  alias Fountain.Agents

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"] — media type is checked
  # against Fountain.Images.valid_media_types/0 and the response pins
  # nosniff + a sandboxing CSP precisely because the bytes are
  # client-originated. Same treatment as TurnImageController.
  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    with %{avatar_media_type: media_type} = agent
         when not is_nil(media_type) <- Agents.get_agent(id, user_id),
         # Re-checked at serve time: a row whose media_type slipped past
         # ingest validation (or predates it) must not be served as active
         # content from the app's own origin, where the page CSP allows
         # 'unsafe-inline'.
         true <- Fountain.Images.valid_media_type?(media_type),
         %{data: data} <- Agents.get_avatar(agent) do
      conn
      |> put_resp_content_type(media_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
