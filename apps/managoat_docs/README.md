# Managoat.Docs

A documentation manual embedded at compile time, so a Phoenix app can serve
it at `/docs` instead of publishing a second site; the markdown renderer
that serves it (and closes the two XSS holes a plain markdown-to-HTML call
leaves open); and the guardrail tests that keep the manual sound. The
guardrails are the point. Each exists because of an incident, and the
library's job is to make them reusable by any app that wants `/docs` inside
it.

```elixir
# lib/my_app/docs.ex: the whole host module
defmodule MyApp.Docs do
  use Managoat.Docs,
    root: Path.expand("../..", __DIR__),   # snippet includes resolve here
    docs_dir: "docs",                       # the pages, relative to root
    nav: "docs/nav.yml",                    # the nav, relative to root
    mount: "/docs",                         # where the manual is served
    extra_resources: ["CHANGELOG.md"],      # other files a page includes
    languages: ~w(bash elixir json)         # parsers the image bakes
end

# A controller
{:ok, page} = MyApp.Docs.get(slug)
render(conn, :show,
  nav: MyApp.Docs.nav(),
  body_html: Managoat.Docs.Markdown.to_trusted_html(page.body),
  search_index_json: MyApp.Docs.search_index_json()
)
# ...and in the template: {Phoenix.HTML.raw(@body_html)}

# test/my_app/docs_test.exs: the guardrails, against the real manual
defmodule MyApp.DocsTest do
  use Managoat.Docs.GuardrailCase, docs: MyApp.Docs, dockerfile: "Dockerfile"
end
```

Every option has the default shown except `root`, which is required.

## The pieces

| Module | Role |
|---|---|
| `Managoat.Docs` | The `use` macro. Reads the nav and every page it names in the host module's body, declares each as an `@external_resource` there (so an edit recompiles in dev), and generates `nav/0`, `nav_source/0`, `slugs/0`, `get/1`, `search_index/0`, `search_index_json/0`, `path_for_slug/1`, `external_resources/0`, `root/0`, `docs_dir/0`, `mount/0` and `languages/0`. |
| `Managoat.Docs.Compiler` | The compile-time transforms: `parse_nav/1`, `preprocess/4` (snippets, admonitions, links), `slug_for/1`, `path_for_slug/2`, `extract_headings/1`. Pure. |
| `Managoat.Docs.Markdown` | Markdown to HTML through [MDEx](https://hexdocs.pm/mdex) (comrak). `to_html/1` for untrusted input, `to_trusted_html/1` for the manual. Both return a binary. |
| `Managoat.Docs.Checks` | The guardrails as functions: each takes the host's docs module and returns a list of failure messages. |
| `Managoat.Docs.GuardrailCase` | The same checks as an ExUnit case template a host `use`s once. |

## The nav

`nav.yml` carries a `nav:` block that is a hand-written list two levels deep,
in two line shapes:

```yaml
nav:
  - Home: index.md
  - Setup: setup.md
  - Guides:
      - Deploy: guides/deploy.md
      - Operate: guides/operate.md
```

`index.md` is the home page (slug `""`); `guides/index.md` is served at the
section's slug, `guides`. The parser reads exactly those two shapes and
**raises at compile time** on anything else: a line it cannot read, a
section inside a section, a page indented past its siblings. A page
silently missing from the manual is the bug the parser exists to make
impossible, so an unreadable nav fails the compile rather than shrinking the
site. Sections are one level deep because the sidebar that embeds this nav
renders exactly a section and its pages; flatten a deeper tree into sibling
sections, or make it headings on a hub page.

## The dialect

Beyond CommonMark and GFM tables, a page may use three things, inherited
from the MkDocs Material site Fountain's manual was published as before it
moved in-app:

| Syntax | Result |
|---|---|
| `--8<-- "path/to/file"` on a line of its own | the file's contents, read relative to `root` at compile time |
| `!!! note "Title"` and a four-space-indented body | a blockquote with a bold title line (`**Note**` when there is no title) |
| `[text](other-page.md#anchor)` | `mount/other-page#anchor`, resolved against the linking page's directory |

Nothing else is rewritten. A page that starts using something beyond this
should be checked as served; there is no second renderer to disagree with.

## The renderer

`to_html/1` walks the parsed document before rendering: every raw-HTML node
is replaced by a text node carrying its source, so the renderer escapes it
and the HTML displays rather than executing; links and images are dropped
unless their URL scheme is on the allowlist (`http`, `https`, `mailto` for
links; `http`, `https` for images; relative URLs for both), after decoding
character references and stripping the whitespace browsers ignore, so
`java&#115;cript:` cannot smuggle a scheme past the check.

`to_trusted_html/1` is the same pipeline with three additions for an
authored manual: a `<figure>`/`<svg>` block is kept as real markup after its
script-bearing subset is scrubbed, every heading gets a GFM-style id so
`#anchor` links resolve, and fenced code is syntax highlighted through
[Lumis](https://hexdocs.pm/lumis), called directly rather than through
MDEx's integration because that needs a NIF build an order of magnitude
larger.

## The Dockerfile trap

The manual is embedded at compile time, so the release image never contains
the pages, only the strings baked out of them. Inside the image, `root` is
whatever the Dockerfile `COPY`d before `mix compile`, and a page or snippet
outside that set does not degrade to a broken link: `mix release` dies on
`File.read!`, no image is produced, CI stays green and the deploy silently
never happens. The two Dockerfile guardrails read `external_resources/0` and
every snippet include and check each against the Dockerfile's `COPY` lines.

Lumis has the same shape of trap. It fetches a language's tree-sitter parser
on first use and caches it under its own `priv/`, which a read-only root
filesystem forbids, so the first highlighted block on such a deployment
renders plain. Bake the parsers before `mix release`:

```dockerfile
RUN mix compile \
 && elixir -e 'Enum.each(Path.wildcard("_build/prod/lib/*/ebin"), &Code.prepend_path/1); {:ok, _} = Application.ensure_all_started(:lumis); {:ok, _} = Lumis.Languages.cache(MyApp.Docs.languages())' \
 && mix release
```

The "covers every language the manual fences" guardrail fails if a page
fences a language `languages/0` does not name, so the gap is caught in CI
rather than noticed in production.

## The guardrails

| Test | Incident |
|---|---|
| every page the nav names exists on disk | |
| every page on disk is named in the nav | a static site build published unlisted pages; with one publisher an unlisted page is published nowhere |
| every nav entry resolves and the home slug is empty | |
| no unsupported syntax survives preprocessing | |
| every internal link targets a page that exists | the static build's `--strict` link check ran on main only; this runs on every PR |
| every internal anchor link targets a heading on that page | MkDocs never checked anchors, and slugged duplicate headings differently from comrak |
| the search index has one entry per page, every heading id resolves, and the JSON has no `</` | the index is inlined into a `<script>`; a `</script` in a heading would close it early |
| every file read at compile time is `COPY`d into the image | a page that snippet-included a file outside the `COPY` set built no image while CI stayed green |
| every snippet path is `COPY`d into the image | the same, found by scanning rather than asking the module |
| every language name is a Lumis id, and every fence is baked | parsers a read-only deployment could not fetch at runtime |

`Managoat.Docs.Checks` has each as a function returning failure messages;
`Managoat.Docs.GuardrailCase` wraps them as tests. The case template takes
`docs:`, an optional `dockerfile:` (relative to `root`; without it the two
Dockerfile tests are not generated) and `unhighlightable:`, the fence
languages exempt from the baked-parser check (default: the names that ask
for no highlighting).

## Where it comes from

Extracted from [Fountain](https://github.com/BinaryBourbon/fountain) under
[ADR 0037](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0037-component-libraries.md).
Fountain's `Fountain.Docs` is one `use` line over its `docs/` directory,
served at `/docs`; its `docs_test.exs` is the case template plus tests about
that manual's content. The fixture manual under `test/fixtures/manual` is
the library's own host.

## Licence

Apache-2.0. See `LICENSE`.
