# Product screenshots

Captured on 2026-09-05 from the real apps in
[managoat/demos](https://github.com/managoat/demos) at
`65ef3c7792de75ce3ba564fb1a80f96f24d4300c`, against Fountain's local API.
The images live in `apps/fountain/priv/static/images/apps/`.

These are fictional, seeded transcripts, not a recorded model run or a benchmark.
The Acorn storefront, `studio@example.com`, agent names, tool output and test
results are fixture data. No external model, sandbox, or credential provider
was called. No API key appears in a screenshot.

| Image | Viewport | State |
| --- | --- | --- |
| `conversations.jpg` | 973 × 791 | Builder running, prompt and tool calls visible, edit result expanded |
| `team.jpg` | 973 × 791 | Builder selected, Reviewer and Researcher in the roster |
| `workbench.jpg` | 973 × 791 | Cart work item, acceptance criteria and Builder assignment |
| `workbench-mobile.jpg` | 390 × 844 | Same work item in the app's phone layout |

The homepage and social card add a CSS phone frame around the unaltered mobile
capture. Desktop captures use the browser's normal viewport. Images are JPEG
as returned by the browser. The social card is a 1200 × 630 capture converted
to PNG to retain the existing public asset path.

## Refresh the captures

1. Use a disposable local database named `fountain_capture_burndown`. With
   `DATABASE_URL` pointing to it and `MIX_ENV=test`, run `mix ecto.create` and
   `mix ecto.migrate`. The scripts refuse a different database name or Mix
   environment. They use the test factory and do not provision machines.
2. From the repository root, run `mix run --no-start scripts/screenshots/seed.exs`
   with those same environment variables. This starts Fountain on loopback
   port 4030 and seeds a fresh dataset. Run it once per fresh database.
   `CAPTURE_DATA_FILE` sets the output file for the local API key and resource
   IDs; its default is `/tmp/fountain-capture-data.json`, with mode 0600.
3. Run Conversations, Team and Workbench from the demos monorepo on loopback
   ports 5174, 5175 and 5176. Point the Workbench backend's `FOUNTAIN_URL` at
   `http://127.0.0.1:4030`. Sign into each app with the disposable local key.
   Browser credential entry may need action-time approval from the operator.
4. In Conversations, open “Make the empty cart feel useful” and expand “Update
   the empty cart”. In Team, select Builder. Capture both at desktop width.
5. In Workbench, create “Acorn storefront” using the `storefront` environment
   and no default teammate. Create “Make the empty cart feel useful” with no
   initial teammate and these notes:

   ```text
   Add a clear empty state with a link back to the catalog.

   Acceptance
   - Explain why the cart is empty.
   - Keep the next action visible on a phone.
   - Cover empty and populated carts with tests.
   ```

6. Read the project and item IDs from the Workbench URL. Run
   `mix run --no-start scripts/screenshots/workitem.exs PROJECT_ID ITEM_ID`
   against the same disposable database. This seeds a completed Builder
   conversation under the work item's channel. Set that item's `agent_ids`
   in the disposable Workbench SQLite database to the JSON array containing
   `agent_id` from the capture data file. Reload the work item.
7. Capture Workbench at desktop width and 390 × 844. Restore the browser's
   viewport override afterward. Inspect every image for clipping, failed
   requests, or credentials before replacing the committed files.

## Social card

Copy `og-card.html`, `conversations.jpg` and `workbench-mobile.jpg` into a
temporary directory. Serve that directory on loopback, open `og-card.html`,
and capture at 1200 × 630. Restore the browser viewport. Convert only the file
encoding to PNG, for example with `sips -s format png capture.jpg --out
apps/fountain/priv/static/images/og-card.png` on macOS.

A deployment with `BRAND_ASSETS_URL` uses its external card instead. Refresh
that bundle separately; changing the built-in file does not change it.
