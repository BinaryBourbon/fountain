defmodule FountainWeb.PromptImages do
  @moduledoc """
  Decodes and validates client-supplied prompt images, for BOTH transports.

  The API controller and the conversation LiveView accept the same
  `[%{"data" => base64, "media_type" => mt}]` shape, and they must apply the
  same three checks — media-type allowlist, non-raising base64 decode, size
  ceiling. The LiveView once skipped all three: malformed base64 raised out
  of `Base.decode64!/1` and took the LiveView process down (crash-logging
  its assigns), and nothing bounded the payload.

  Validates before anything is stored, and returns an error the caller can
  render. Returns `{:ok, [%{media_type: mt, data: binary}]}` or
  `{:error, message}`.
  """

  @max_image_bytes 10 * 1024 * 1024

  def max_image_bytes, do: @max_image_bytes

  def decode(nil), do: {:ok, []}
  def decode([]), do: {:ok, []}

  def decode(images) when is_list(images) do
    Enum.reduce_while(images, {:ok, []}, fn img, {:ok, acc} ->
      case decode_image(img) do
        {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def decode(_), do: {:error, "images must be a list"}

  defp decode_image(img) when is_map(img) do
    b64 = img["data"] || img[:data]
    mt = img["media_type"] || img[:media_type]

    with :ok <- validate_media_type(mt),
         {:ok, data} <- decode_base64(b64),
         :ok <- validate_size(data) do
      {:ok, %{media_type: mt, data: data}}
    end
  end

  defp decode_image(_), do: {:error, "each image must be an object"}

  defp validate_media_type(mt) do
    if Fountain.Images.valid_media_type?(mt) do
      :ok
    else
      {:error,
       "unsupported image media_type #{inspect(mt)} — must be one of " <>
         Enum.join(Fountain.Images.valid_media_types(), ", ")}
    end
  end

  defp decode_base64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, "image data must be base64-encoded"}
    end
  end

  defp decode_base64(_), do: {:error, "image data is required"}

  defp validate_size(data) do
    if byte_size(data) > @max_image_bytes,
      do: {:error, "image exceeds the 10MB limit"},
      else: :ok
  end
end
