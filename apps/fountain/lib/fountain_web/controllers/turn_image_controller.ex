defmodule FountainWeb.TurnImageController do
  use FountainWeb, :controller

  alias Fountain.Conversations

  def show(conn, %{"conversation_id" => conv_id, "turn_id" => turn_id, "position" => pos_str}) do
    with {position, ""} <- Integer.parse(pos_str),
         turn when not is_nil(turn) <- Conversations.get_turn_by_conversation(turn_id, conv_id),
         image when not is_nil(image) <- Conversations.get_turn_image(turn_id, position) do
      conn
      |> put_resp_content_type(image.media_type)
      |> send_resp(200, image.data)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end
end
