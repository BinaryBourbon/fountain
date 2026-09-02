defmodule Managoat.Docs.Checks do
  @moduledoc """
  The structural checks on an embedded manual, as functions that return a
  list of failure messages (empty when the manual is sound).
  `Managoat.Docs.GuardrailCase` wraps each one as an ExUnit test; they are
  functions first so a host can run one from a script, a release task or a
  test of its own shape.

  Each check exists because of an incident. The messages say which, and what
  to do; they are kept verbatim from Fountain's `docs_test.exs` because they
  are the documentation of the incident and better than a summary of it.

  Every function takes the host's docs module (the one that `use`s
  `Managoat.Docs`) and reads the manual through its generated functions, so
  a check runs against what the module *embedded*, not a re-read of the
  files.
  """

  @typedoc "A failure message. An empty list is a pass."
  @type failure :: String.t()

  @doc """
  Every `--8<-- "path"` snippet include in the manual points at a file that
  exists and that the Dockerfile `COPY`s into the build stage.

  The manual inlines snippets at *compile time*, reading from `root`. Inside
  the image that root is whatever the Dockerfile COPYed, so a snippet
  pointing outside it does not degrade: `mix release` dies on `File.read!`
  and no image is produced at all. That is a silent failure in the worst
  place: CI is green, the PR merges, and the deploy simply never happens. It
  has happened once (Fountain's `docs/tour.md` including an SDK example).
  """
  @spec snippets_copied(module(), Path.t()) :: [failure()]
  def snippets_copied(docs, dockerfile) do
    copied = dockerfile_copies(dockerfile)

    for {page, path} <- snippet_paths(docs),
        failure <- copy_failures(docs, copied, path, "#{page} includes #{path}"),
        do: failure
  end

  @doc """
  Every file the docs module reads at compile time (`external_resources/0`)
  exists and is `COPY`d into the image's build stage.

  The generalisation of `snippets_copied/2`. Snippets are found by scanning
  markdown; this asks the module itself what it read, so a *new kind* of
  compile-time dependency is covered without anyone remembering to extend a
  scanner. The nav file is the case that motivated it: it is parsed at
  compile time, and nothing about a snippet scan would ever have noticed it
  was missing from the Dockerfile.
  """
  @spec external_resources_copied(module(), Path.t()) :: [failure()]
  def external_resources_copied(docs, dockerfile) do
    copied = dockerfile_copies(dockerfile)

    for path <- docs.external_resources(),
        failure <- copy_failures(docs, copied, path, "#{inspect(docs)} reads #{path}"),
        do: failure
  end

  defp copy_failures(docs, copied, path, what) do
    cond do
      not File.exists?(Path.join(docs.root(), path)) ->
        ["#{what}, which does not exist"]

      not Enum.any?(copied, &covers?(&1, path)) ->
        [
          """
          #{what} at compile time, and the Dockerfile does not COPY it into
          the build stage. This does not break a link: it breaks `mix release`,
          so no image is built, CI stays green and the deploy never happens.
          Add a COPY for it beside the one for the docs directory.
          """
        ]

      true ->
        []
    end
  end

  @doc "The source of every plain `COPY src dst` line in a Dockerfile (flags such as `--from` excluded)."
  @spec dockerfile_copies(Path.t()) :: [String.t()]
  def dockerfile_copies(dockerfile) do
    dockerfile
    |> File.read!()
    |> then(&Regex.scan(~r/^COPY\s+(?!--)(\S+)\s+\S+$/m, &1))
    |> Enum.map(fn [_, source] -> source end)
  end

  @doc "`{page, path}` for every snippet include in the manual's source pages."
  @spec snippet_paths(module()) :: [{String.t(), String.t()}]
  def snippet_paths(docs) do
    for file <- pages_on_disk(docs),
        [_, path] <- Regex.scan(~r/^--8<--\s+"([^"]+)"\s*$/m, File.read!(file)),
        do: {Path.relative_to(file, docs.root()), path}
  end

  # `COPY docs ./docs` covers `docs/x.md`; `COPY CHANGELOG.md ./` covers itself.
  defp covers?(source, path) do
    path == source or String.starts_with?(path, source <> "/")
  end

  @doc "Every page the nav names exists on disk."
  @spec nav_pages_exist(module()) :: [failure()]
  def nav_pages_exist(docs) do
    for {_title, file} <- Managoat.Docs.Compiler.flat_pages(docs.nav_source()),
        not File.exists?(Path.join(docs.docs_dir(), file)),
        do: "the nav lists #{file}, which does not exist"
  end

  @doc """
  Every `.md` page on disk under the docs directory is named in the nav.

  The other direction, and the one Fountain had no gate for while a static
  site build still existed. MkDocs built every page under `docs/` whether
  the nav named it or not, so a page left out of the nav was still reachable
  on the published site and its absence from the in-app manual looked like a
  rendering quirk rather than a mistake. Four such pages had accumulated.

  With one publisher, a page missing from the nav is a page that is
  published nowhere at all: written, merged, and invisible. There is no
  allowlist on purpose. Somewhere else in the repository is the right home
  for a markdown file nobody should read here.
  """
  @spec pages_on_disk_named(module()) :: [failure()]
  def pages_on_disk_named(docs) do
    named =
      MapSet.new(Managoat.Docs.Compiler.flat_pages(docs.nav_source()), fn {_t, file} -> file end)

    dir = docs.docs_dir()
    rel = fn file -> Path.relative_to(file, dir) end

    case docs |> pages_on_disk() |> Enum.map(rel) |> Enum.reject(&MapSet.member?(named, &1)) do
      [] ->
        []

      orphans ->
        [
          """
          These pages are under #{rel_root(docs, dir)}/ but not in the nav:

          #{Enum.map_join(orphans, "\n", &("  " <> &1))}

          #{docs.mount()} is the only place the manual is published, so a page
          the nav does not name is published nowhere. Add it to the nav, or
          move it out of #{rel_root(docs, dir)}/.
          """
        ]
    end
  end

  @doc "Every slug resolves to a page with a title and a non-empty body, and the home page is at `\"\"`."
  @spec pages_resolve(module()) :: [failure()]
  def pages_resolve(docs) do
    home =
      case docs.get("") do
        {:ok, _} -> []
        :error -> ["there is no home page: the nav names no index.md"]
      end

    home ++
      for slug <- docs.slugs(), failure <- page_failures(docs, slug), do: failure
  end

  defp page_failures(docs, slug) do
    case docs.get(slug) do
      {:ok, %{title: title, body: body}} when is_binary(title) and is_binary(body) ->
        if String.trim(body) == "", do: ["#{inspect(slug)} has an empty body"], else: []

      other ->
        ["#{inspect(slug)} does not resolve: #{inspect(other)}"]
    end
  end

  @doc """
  No authoring syntax survives preprocessing: every relative `.md` link was
  rewritten to a path under the mount, every admonition became a blockquote,
  every snippet include was expanded. A page that introduces syntax the
  compiler does not rewrite is caught here.
  """
  @spec no_leftover_syntax(module()) :: [failure()]
  def no_leftover_syntax(docs) do
    for slug <- docs.slugs(), failure <- leftover_failures(docs, slug), do: failure
  end

  defp leftover_failures(docs, slug) do
    {:ok, %{body: body}} = docs.get(slug)

    [
      {Regex.match?(~r/\]\((?!https?:)[^)]*\.md/, body), "unrewritten .md link"},
      {Regex.match?(~r/^!!!/m, body), "unrewritten admonition"},
      {String.contains?(body, "--8<--"), "unexpanded snippet include"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {_, what} -> "#{what} in #{inspect(slug)}" end)
  end

  @doc "Every internal link under the mount targets a page that exists."
  @spec internal_links_resolve(module()) :: [failure()]
  def internal_links_resolve(docs) do
    slugs = MapSet.new(docs.slugs())
    mount = Regex.escape(docs.mount())

    for slug <- docs.slugs(),
        {:ok, %{body: body}} = docs.get(slug),
        [_, target] <- Regex.scan(~r{\]\(#{mount}(/[^)#]+)?(?:#[^)]*)?\)}, body),
        target_slug = String.trim_leading(target, "/"),
        not MapSet.member?(slugs, target_slug),
        do: "#{inspect(slug)} links to #{docs.path_for_slug(target_slug)}, which is not a page"
  end

  @doc """
  Every internal `#anchor` link targets a heading id on the rendered target
  page. The rendered HTML is the ground truth: `to_trusted_html/1` gives
  every heading a GFM-style id, and comrak's slug is the only one that
  matters. (The MkDocs build that slugged the same headings differently for
  *duplicate* headings, comrak `-1` against python-markdown `_1`, is the
  reason no second slugging pass is allowed.)
  """
  @spec anchors_resolve(module()) :: [failure()]
  def anchors_resolve(docs) do
    rendered = rendered_pages(docs)
    mount = Regex.escape(docs.mount())

    for slug <- docs.slugs(),
        {:ok, %{body: body}} = docs.get(slug),
        [_, target, anchor] <- Regex.scan(~r{\]\(#{mount}(/[^)#]+)?#([^)]+)\)}, body),
        target_slug = String.trim_leading(target, "/"),
        target_html = Map.get(rendered, if(target == "", do: slug, else: target_slug), ""),
        not String.contains?(target_html, ~s( id="#{anchor}")),
        do:
          "#{inspect(slug)} links to #{docs.path_for_slug(target_slug)}##{anchor}, " <>
            "but that page has no heading with that id"
  end

  @doc "The search index has exactly one entry per page."
  @spec search_index_complete(module()) :: [failure()]
  def search_index_complete(docs) do
    indexed = docs.search_index() |> Enum.map(& &1.slug) |> Enum.sort()
    slugs = Enum.sort(docs.slugs())

    if indexed == slugs,
      do: [],
      else: ["the search index covers #{inspect(indexed)} but the pages are #{inspect(slugs)}"]
  end

  @doc """
  Every heading id in the search index resolves on its own rendered page,
  and no heading has empty text. Same ground truth as `anchors_resolve/1`.
  """
  @spec search_index_headings_resolve(module()) :: [failure()]
  def search_index_headings_resolve(docs) do
    rendered = rendered_pages(docs)

    for %{slug: slug, headings: headings} <- docs.search_index(),
        %{id: id, text: text} <- headings,
        failure <- heading_failures(rendered, slug, id, text),
        do: failure
  end

  defp heading_failures(rendered, slug, id, text) do
    empty = if text == "", do: ["#{inspect(slug)} has a heading with empty text"], else: []

    missing =
      if String.contains?(Map.fetch!(rendered, slug), ~s( id="#{id}")),
        do: [],
        else: [
          "#{inspect(slug)}'s search index has heading #{inspect(id)}, " <>
            "but the page has no such id"
        ]

    empty ++ missing
  end

  @doc """
  `search_index_json/0` round-trips through JSON to the same number of
  entries as `search_index/0`, and contains no `</` that could close the
  `<script>` tag a layout inlines it into.
  """
  @spec search_index_json_safe(module()) :: [failure()]
  def search_index_json_safe(docs) do
    json = docs.search_index_json()

    closes =
      if String.contains?(json, "</"),
        do: ["search_index_json/0 contains `</`, which can close an inlining <script> tag early"],
        else: []

    expected = length(docs.search_index())

    round_trip =
      case Jason.decode(json) do
        {:ok, decoded} when length(decoded) == expected -> []
        {:ok, decoded} -> ["search_index_json/0 decodes to #{length(decoded)} entries"]
        {:error, _} -> ["search_index_json/0 is not valid JSON"]
      end

    closes ++ round_trip
  end

  @doc """
  Every name in `languages/0` is a Lumis language id, so the Dockerfile's
  `Lumis.Languages.cache/1` step succeeds.
  """
  @spec languages_known(module()) :: [failure()]
  def languages_known(docs) do
    ids = MapSet.new(Lumis.available_languages(), & &1.id)

    for name <- docs.languages(), not MapSet.member?(ids, name) do
      "#{name} is not a Lumis language id; the Dockerfile's cache step would fail the build"
    end
  end

  @doc """
  Every fenced code block in the manual (compiled bodies, so snippet
  includes count) names a language whose parser `languages/0` bakes, or one
  in `unhighlightable`. A fence in a language that is not baked renders
  unhighlighted in production and nowhere else, which is how it goes
  unnoticed (Fountain #879).

  `unhighlightable` names the fences exempt from the rule: the ones that ask
  for no highlighting (`text`, `plain`, ...) and the ones Lumis has no
  parser for. Adding to it means checking that Lumis really has no parser,
  not that baking one is inconvenient.
  """
  @spec fences_baked(module(), [String.t()]) :: [failure()]
  def fences_baked(docs, unhighlightable) do
    fences =
      for slug <- docs.slugs(),
          {:ok, %{body: body}} = docs.get(slug),
          [_, info] <- Regex.scan(~r/^\s*```([a-zA-Z0-9_+-]+)\s*$/m, body),
          uniq: true,
          do: {inspect(slug), info}

    unbaked_fences(docs.languages(), fences, unhighlightable)
  end

  @doc """
  `fences_baked/2` over an explicit `{where, info}` list, for a host that has
  authored markdown outside the manual (an in-app help directory, say).
  `fenced_languages/1` scans files into that shape.
  """
  @spec unbaked_fences([String.t()], [{String.t(), String.t()}], [String.t()]) :: [failure()]
  def unbaked_fences(languages, fences, unhighlightable) do
    baked = MapSet.new(languages)
    by_alias = Map.new(Lumis.available_languages(), &{&1.id, &1.id})

    aliases =
      for l <- Lumis.available_languages(), a <- l.aliases, into: by_alias, do: {a, l.id}

    for {where, info} <- fences,
        info not in unhighlightable,
        id = Map.get(aliases, info, info),
        not MapSet.member?(baked, id) do
      "#{where} fences ```#{info} (#{id}), which is not in the baked language list"
    end
  end

  @doc "`{file, info}` for every fence in the given markdown files."
  @spec fenced_languages([Path.t()]) :: [{String.t(), String.t()}]
  def fenced_languages(files) do
    for file <- files,
        File.exists?(file),
        [_, info] <- Regex.scan(~r/^\s*```([a-zA-Z0-9_+-]+)\s*$/m, File.read!(file)),
        uniq: true,
        do: {file, info}
  end

  # Every page rendered once, keyed by slug: the anchor and heading checks
  # both read ids from this.
  defp rendered_pages(docs) do
    Map.new(docs.slugs(), fn slug ->
      {:ok, %{body: body}} = docs.get(slug)
      {slug, Managoat.Docs.Markdown.to_trusted_html(body)}
    end)
  end

  defp pages_on_disk(docs) do
    [docs.docs_dir(), "**", "*.md"] |> Path.join() |> Path.wildcard()
  end

  defp rel_root(docs, path), do: Path.relative_to(path, docs.root())
end
