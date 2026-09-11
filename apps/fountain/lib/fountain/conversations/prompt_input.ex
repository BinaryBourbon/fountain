defmodule Fountain.Conversations.PromptInput do
  @moduledoc """
  Validate opening input before a launch reserves a sandbox or creates a conversation.

  `validate_initial/1` runs as the first step of `start_conversation/2` on both
  the create and attach paths, ahead of the agent fetch and every reservation,
  so malformed input costs no machine.

  The rule is that images need words. A launch with neither is fine — that is
  how a conversation opens without a first turn — but images with a blank or
  absent prompt are refused, because the runtime is handed pixels and no
  instruction. The OpenAI-compatible controller decides the other way for its
  own dialect and synthesizes a caption
  (`FountainWeb.OpenAIController.non_empty/2`); that is a shim for clients that
  cannot send one, not the native contract.

  The media-type and size checks repeat what `FountainWeb.PromptImages.decode/1`
  already did. That is deliberate: `decode/1` belongs to the two HTTP
  transports, and a context caller (`Fountain.Team`, a schedule, a future
  worker) reaches `start_conversation/2` without passing through it. The web
  layer's message is the friendlier one and still wins for HTTP callers,
  because it runs first.

  Images may arrive string-keyed or atom-keyed. `decode/1` hands back atom keys
  and every current caller routes through it, but a context caller building the
  map itself should not get `:invalid_images` for a valid image.
  """

  alias Fountain.Images

  @doc """
  `:ok`, `{:error, :invalid_prompt}` or `{:error, :invalid_images}` for the
  opening `prompt` and `images` of a launch. Both keys are optional; `attrs`
  is the string-keyed map `start_conversation/2` takes.
  """
  @spec validate_initial(map()) :: :ok | {:error, :invalid_prompt | :invalid_images}
  def validate_initial(attrs) do
    case {attrs["prompt"], attrs["images"] || []} do
      {prompt, []} when prompt in [nil, ""] -> :ok
      {prompt, images} -> validate_payload(prompt, images)
    end
  end

  defp validate_payload(prompt, images) when is_binary(prompt) and is_list(images) do
    cond do
      String.trim(prompt) == "" -> {:error, :invalid_prompt}
      Enum.any?(images, &(not valid_image?(&1))) -> {:error, :invalid_images}
      true -> :ok
    end
  end

  defp validate_payload(_, _), do: {:error, :invalid_prompt}

  # `Map.get/2`, not `image[...]`: a struct would raise out of Access.
  defp valid_image?(image) when is_map(image) do
    media_type = Map.get(image, :media_type) || Map.get(image, "media_type")
    data = Map.get(image, :data) || Map.get(image, "data")

    is_binary(data) and Images.valid_media_type?(media_type) and byte_size(data) > 0 and
      byte_size(data) <= Images.max_prompt_image_bytes()
  end

  defp valid_image?(_), do: false
end
