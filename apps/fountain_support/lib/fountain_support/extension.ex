defmodule FountainSupport.Extension do
  @moduledoc """
  The one module the host knows about (ADR 0043, #1528).

  `config :fountain, :extensions, [..., FountainSupport.Extension]` is the whole
  of Fountain's knowledge of problem reports. Nothing under `apps/fountain/lib`
  names this module or any other `FountainSupport.*` one —
  `Fountain.ExtensionGuardTest` fails the build if that stops being true.

  ## Three callbacks, and no tenth

  This is the extraction that proves the seam against a second feature *without
  widening it*. Buzz needed nine callbacks because it has a supervision tree, a
  cron sweep and two admin figures. A problem report has none of that, so this
  implements three and inherits the contribute-nothing default for the other
  six:

    * `api_mounts/0` — one mount, `/support`.
    * `migrations/0` — the extension's own migration directory.
    * `openapi_paths/0` — the three report operations.

  In particular there is no `oban_cron/0` entry. The forwarder is enqueued by
  `FountainSupport.create_report/3`, this app's own context, so the host's
  configuration never names a worker a core-only release does not carry — which
  is the only reason that callback exists.
  """

  use Fountain.Extension, id: :support

  @doc """
  The one path this extension serves: `/api/support`.

  `/api/support/reports` and `/api/support/reports/:id` are written relative to
  it in `FountainSupport.Router`, so they are served exactly where they were as
  core routes.
  """
  @impl true
  def api_mounts, do: [{"/support", FountainSupport.Router}]

  @doc """
  The `support_reports` table's migration, now this app's.

  The version number is unchanged, so a database that already applied it through
  the core path keeps it applied: `schema_migrations` is keyed by version and
  never by path (`Fountain.Migrations`). Moving the file is not an upgrade step
  for any existing deployment — `FountainSupport.UpgradeTest` asserts it against
  a database that really did apply it before the move.
  """
  @impl true
  def migrations, do: [{:fountain_support, "repo/migrations"}]

  @doc """
  The same three operations, at the same paths, with the same `operationId`s and
  schema titles they had as core routes.

  The published spec is the bundled spec, so these appear in `dist/openapi.json`
  and in `sdk/contract/contract.json` exactly as they did before the move — the
  SDK contract gate is what proves it.
  """
  @impl true
  def openapi_paths, do: Fountain.Extensions.mounted_paths("/support", FountainSupport.Router)
end
