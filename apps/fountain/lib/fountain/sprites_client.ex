defmodule Fountain.SpritesClient do
  @moduledoc """
  Lazy access to the configured Sprites client. Reads SPRITES_TOKEN from
  application env (set in runtime.exs).
  """

  @doc "Returns a Sprites client, or raises if SPRITES_TOKEN is not set."
  def get! do
    token =
      Application.get_env(:fountain, :sprites_token) ||
        raise "SPRITES_TOKEN is not set — cannot talk to sprites.dev"

    base_url = Application.get_env(:fountain, :sprites_base_url, "https://api.sprites.dev")
    Sprites.new(token, base_url: base_url)
  end
end
