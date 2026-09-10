defmodule Fountain.Conversations.PromptInput do
  @moduledoc "Validate opening input before a launch reserves a sandbox or creates a conversation."

  alias Fountain.Images

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

  defp valid_image?(%{media_type: media_type, data: data}) when is_binary(data),
    do:
      Images.valid_media_type?(media_type) and byte_size(data) > 0 and
        byte_size(data) <= Images.max_prompt_image_bytes()

  defp valid_image?(_), do: false
end
