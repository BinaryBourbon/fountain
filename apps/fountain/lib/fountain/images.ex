defmodule Fountain.Images do
  @moduledoc """
  The image media types the platform accepts, in one place.

  Every path that stores or serves client-originated image bytes — turn
  images and agent avatars — must validate against this same list at ingest
  AND re-check at serve time. The avatar path once validated nothing while
  the turn-image path next to it validated both ends, and the asymmetry is
  how a client-declared `text/html` ended up servable from the app's own
  origin. A shared list keeps the two from diverging again.
  """

  @valid_media_types ~w(image/png image/jpeg image/gif image/webp)

  def valid_media_types, do: @valid_media_types

  def valid_media_type?(media_type), do: media_type in @valid_media_types
end
