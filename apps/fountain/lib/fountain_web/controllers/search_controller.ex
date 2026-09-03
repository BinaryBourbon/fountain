defmodule FountainWeb.SearchController do
  @moduledoc """
  `GET /api/search` (#826): full-text search across the caller's
  conversations — titles, prompts, replies — for a client's command palette.
  A thin wrapper over `Fountain.Search`, which scopes every source by the
  caller in the query itself.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Search
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Search"])

  operation(:index,
    summary: "Search conversations, prompts and replies",
    description:
      "Full-text search over the caller's conversation titles, turn prompts and " <>
        "assistant replies (`kind`: `title`, `prompt`, `reply`), ranked, newest first " <>
        "among equals. Postgres `websearch` syntax: `\"quoted phrase\"`, `-excluded`, " <>
        "`or`; matching is exact-token (no stemming), so identifiers and code " <>
        "fragments match as themselves. Each hit names the conversation, agent and " <>
        "turn to jump to, with a plain-text `snippet` (no markup) and the turn's " <>
        "(or conversation's) creation time as `ts`. A reply is searchable once its " <>
        "turn ends. Page with `limit` / `offset` while `meta.has_more`.",
    parameters: [
      q: [in: :query, type: :string, required: true, description: "The search text."],
      limit: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: Search.max_limit()},
        required: false,
        description: "Page size; default 20, max #{Search.max_limit()}."
      ],
      offset: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :integer, minimum: 0},
        required: false,
        description: "Hits to skip; default 0."
      ],
      agent_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Only this agent's conversations."
      ],
      conversation_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Only this conversation."
      ],
      since: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
        required: false,
        description: "Only hits whose `ts` is at or after this instant (RFC 3339)."
      ],
      kinds: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated subset of `title,prompt,reply`; default all."
      ]
    ],
    responses: [
      ok: {"Hits", "application/json", Schemas.SearchResponse},
      bad_request: {"Blank `q`", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Missing `q`, or a malformed parameter", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user = conn.assigns.current_user

    with {:ok, q} <- fetch_q(params),
         {:ok, since} <- parse_since(params["since"]) do
      result =
        Search.search(user.id, q,
          limit: parse_int(params["limit"], 20),
          offset: parse_int(params["offset"], 0),
          agent_id: params["agent_id"],
          conversation_id: params["conversation_id"],
          since: since,
          kinds: parse_kinds(params["kinds"])
        )

      render(conn, :index, result: result)
    end
  end

  defp fetch_q(%{"q" => q}) when is_binary(q) do
    case String.trim(q) do
      "" -> {:error, "q_required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_q(_), do: {:error, "q_required"}

  # `replace_params: false` leaves query params as strings; the spec has
  # already validated the shape, so a parse failure here is only the default.
  defp parse_int(nil, default), do: default
  defp parse_int(n, _default) when is_integer(n), do: n

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_since(nil), do: {:ok, nil}
  defp parse_since(%DateTime{} = dt), do: {:ok, dt}

  defp parse_since(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, "invalid_since"}
    end
  end

  defp parse_kinds(nil), do: nil
  defp parse_kinds(""), do: nil

  defp parse_kinds(s) when is_binary(s) do
    kinds = s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    # An unknown kind is ignored rather than refused: `Fountain.Search`
    # returns nothing for it, which is the honest answer.
    Enum.filter(kinds, &(&1 in Search.kinds()))
  end
end
