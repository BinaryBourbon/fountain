defmodule FountainWeb.TurnImageController do
  @moduledoc false
  use FountainWeb, :controller

  alias Fountain.Conversations
  alias Fountain.Conversations.TurnImage

  def show(conn, %{"conversation_id" => conv_id, "turn_id" => turn_id, "position" => pos_str}) do
    user_id = conn.assigns.current_user.id

    with {position, ""} <- Integer.parse(pos_str),
         {:ok, conv_id} <- Ecto.UUID.cast(conv_id),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         turn when not is_nil(turn) <-
           Conversations.get_turn_by_conversation(turn_id, conv_id, user_id),
         # Ownership established by the scoped turn lookup above.
         image when not is_nil(image) <- Conversations._unsafe_get_turn_image(turn.id, position),
         true <- image.media_type in TurnImage.valid_media_types() do
      conn
      |> put_resp_content_type(image.media_type)
      # Stored bytes and their media_type both originate from client input, so
      # pin the type the browser is allowed to infer. Without this a row whose
      # media_type slipped past ingest validation would be served as active
      # content from the app's own origin.
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, image.data)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end
end
