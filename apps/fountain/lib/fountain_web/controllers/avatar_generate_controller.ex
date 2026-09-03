defmodule FountainWeb.AvatarGenerateController do
  @moduledoc """
  `POST /api/avatars/generate`: the agent form's "generate an avatar" over the
  API (#815). Same generator as the web form (`Fountain.AvatarGenerator`,
  OpenAI Images with the tenant's own OpenAI credential); returns the PNG as
  base64 for the client to preview and then attach with
  `PUT /api/agents/:id/avatar` — generation is not tied to an agent, so a
  client can generate before the agent exists, as the form does.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.AvatarGenerator
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Agents"])

  operation(:create,
    summary: "Generate an avatar image",
    description:
      "Generates a square PNG avatar with the tenant's OpenAI credential from a `base` " <>
        "and a `mood` (`GET /api/catalog` lists both). Returns base64 `data` and " <>
        "`media_type` in the shape `PUT /api/agents/:id/avatar` accepts. 422 " <>
        "`no_openai_key` when the tenant has no OpenAI credential; 502 when the " <>
        "provider refused.",
    request_body: {"Base and mood", "application/json", Schemas.AvatarGenerateRequest},
    responses: [
      ok: {"Generated image", "application/json", Schemas.AvatarGenerateResponse},
      unprocessable_entity:
        {"No OpenAI credential, or unknown base/mood", "application/json", Schemas.Error},
      bad_gateway: {"The image provider refused", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"base" => base, "mood" => mood}) do
    user = conn.assigns.current_user

    with :ok <- check_choice(base, AvatarGenerator.bases(), "base"),
         :ok <- check_choice(mood, AvatarGenerator.moods(), "mood") do
      case AvatarGenerator.generate(user.id, base, mood) do
        {:ok, png} ->
          json(conn, %{data: %{data: Base.encode64(png), media_type: "image/png"}})

        {:error, :no_openai_key} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: "no_openai_key",
            message: "Add an OpenAI credential under inference credentials to generate avatars."
          })

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "avatar_generation_failed", message: to_string_reason(reason)})
      end
    end
  end

  defp check_choice(value, allowed, field) do
    if value in allowed do
      :ok
    else
      {:error, "unknown #{field}: #{inspect(value)} (one of #{Enum.join(allowed, ", ")})"}
    end
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
