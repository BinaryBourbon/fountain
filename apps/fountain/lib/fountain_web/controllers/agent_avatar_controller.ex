defmodule FountainWeb.AgentAvatarController do
  @moduledoc false
  use FountainWeb, :controller

  alias Fountain.Agents

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    with %{avatar_media_type: media_type} = agent
         when not is_nil(media_type) <- Agents.get_agent(id, user_id),
         %{data: data} <- Agents.get_avatar(agent) do
      conn
      |> put_resp_content_type(media_type)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
