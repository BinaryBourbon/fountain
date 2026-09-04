defmodule FountainBuzz.McpRouter do
  @moduledoc """
  The MCP transport a hosted Buzz agent's sandbox posts to, mounted by the host
  at `/api/mcp/buzz`.

  A second mount rather than a path under `/api/buzz`, because
  `/api/mcp/buzz/:conversation_id` is the path this endpoint has always had and
  ADR 0043 decision 6 keeps it. It is also the reason the seam grew
  `api_mounts/0`: `/api/mcp/buzz` is not under `/api/buzz`, and one prefix could
  not express both (#1507).

  The host's own `/api/mcp/team/:id`, `/api/mcp/caller/:id` and
  `/api/mcp/gmail/...` are core routes declared before the extension dispatch,
  so they win; `Fountain.Extensions.validate!/0` refuses a mount that overlaps
  any of them, and `/mcp/buzz` overlaps none.
  """
  use Phoenix.Router

  scope "/" do
    post "/:conversation_id", FountainBuzz.McpController, :handle
  end
end
