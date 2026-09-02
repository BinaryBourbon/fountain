defmodule Managoat.Docs.Fixture do
  @moduledoc """
  The fixture manual under `test/fixtures/manual`, embedded the way a host
  embeds its own: one `use` line. The library's guardrail tests run against
  this; a host's run against its real manual.

  The fixture is small on purpose and exercises every part of the dialect:
  a section, a snippet include from outside the docs directory (the
  changelog, declared as an `extra_resources:` entry), an admonition with a
  custom title and one without, relative links with and without anchors from
  both a top-level page and a section page, duplicate headings on one page,
  a kept `<figure>`/`<svg>` block, and fences in three baked languages plus
  one that asks for no highlighting.
  """

  use Managoat.Docs,
    root: Path.expand("../..", __DIR__),
    docs_dir: "test/fixtures/manual",
    nav: "test/fixtures/manual/nav.yml",
    mount: "/manual",
    extra_resources: ["test/fixtures/snippets/CHANGELOG.md"],
    languages: ~w(bash elixir json)
end
