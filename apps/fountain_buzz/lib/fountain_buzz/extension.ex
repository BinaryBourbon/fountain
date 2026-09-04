defmodule FountainBuzz.Extension do
  @moduledoc """
  The one module the host knows about (ADR 0043, #1507).

  `config :fountain, :extensions, [FountainBuzz.Extension]` is the whole of
  Fountain's knowledge of Buzz. Nothing under `apps/fountain/lib` names this
  module or any other `FountainBuzz.*` one — `Fountain.ExtensionGuardTest`
  fails the build if that stops being true.

  Everything here is a thin delegation. Policy lives in the contexts it
  delegates to, so this file stays readable as "what the host can ask".
  """

  use Fountain.Extension, id: :buzz

  @doc """
  The two paths ADR 0043 decision 6 promises to keep.

  `/api/buzz` carries the agent CRUD a provider deploy drives; `/api/mcp/buzz`
  carries the MCP transport a hosted agent's sandbox posts to. The second is not
  under the first, which is why the seam takes mounts rather than one prefix.
  """
  @impl true
  def api_mounts do
    [
      {"/buzz", FountainBuzz.Router},
      {"/mcp/buzz", FountainBuzz.McpRouter}
    ]
  end

  @doc """
  The identity table's migrations, now this app's.

  The version numbers are unchanged, so a database that already applied them
  through the core path keeps them applied: `schema_migrations` is keyed by
  version and never by path (`Fountain.Migrations`). Moving these files is not
  an upgrade step for any existing deployment.
  """
  @impl true
  def migrations, do: [{:fountain_buzz, "repo/migrations"}]

  @doc """
  The same operations, at the same paths, with the same `operationId`s and
  schema titles they had as core routes.

  Both mounts contribute. The published spec is the bundled spec (ADR 0043
  decision 6), so these appear in `dist/openapi.json` and in
  `sdk/contract/contract.json` exactly as they did before the move — the SDK
  contract gate is what proves it.
  """
  @impl true
  def openapi_paths do
    Map.merge(
      Fountain.Extensions.mounted_paths("/buzz", FountainBuzz.Router),
      Fountain.Extensions.mounted_paths("/mcp/buzz", FountainBuzz.McpRouter)
    )
  end

  @doc """
  The reply tools, for a Buzz-driven conversation and no other.

  `FountainBuzz.conversation_mcp_servers/2` decides both whether this
  conversation is one of ours and what the sandbox is told; the callback token
  is the host's conversation-scoped credential, unchanged.
  """
  @impl true
  defdelegate conversation_mcp_servers(conversation_id, callback_token), to: FountainBuzz

  @doc """
  The running-harness count, for the admin overview (#1519).

  A harness is a standing OS process on these pods that no sandbox meter
  reports, so this number exists nowhere else.
  """
  @impl true
  def admin_overview do
    [
      {"Buzz runtimes", FountainBuzz.Manager.running_count(),
       navigate: "/admin/users", note: "running now · owners ↗"}
    ]
  end

  @doc """
  Hosted agents per account, for the admin users table (#1017).

  Highlighted at the ceiling, because the ceiling is this extension's policy and
  the host does not know what one means. One grouped query for the page.
  """
  @impl true
  def admin_user_columns do
    counts = FountainBuzz.identity_counts()
    ceiling = FountainBuzz.identity_ceiling()

    cells =
      Map.new(counts, fn {user_id, count} ->
        {user_id, %{value: count, alert?: count >= ceiling}}
      end)

    [{"Buzz agents", cells}]
  end

  @doc """
  The reconciliation sweep (#1017): stop a harness whose tenant cannot spend,
  start one whose tenant can again.

  Declared here rather than in the host's `config :fountain, Oban` because a
  core-only release must not name a worker module it does not carry. The queue
  and the Oban instance are still the host's — the extension shares the Repo and
  the job table, and pretending otherwise would mean running a second Oban.
  """
  @impl true
  def oban_cron, do: [{"*/15 * * * *", FountainBuzz.Workers.HarnessSweep}]

  @doc """
  The two manual pages this extension owns (#1510).

  They kept their slugs across the move, so `/docs/integrations/buzz` and
  `/docs/catalog/mcp-servers/fountain-buzz` are the same URLs they always were
  — on a bundled distribution. A core one serves neither, and its sidebar never
  names them.
  """
  @impl true
  def docs, do: FountainBuzz.Docs
end
