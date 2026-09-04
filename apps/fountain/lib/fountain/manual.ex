defmodule Fountain.Manual do
  @moduledoc """
  The manual `/docs` serves: `Fountain.Docs` plus every installed extension's
  (ADR 0043, #1510).

  Everything that renders the manual asks this module rather than
  `Fountain.Docs` directly. `Fountain.Docs` is still the core manual and is
  unchanged; this is the composition point, the way
  `FountainWeb.ApiSpec.Compose` is for the OpenAPI document.

  ## Why a callback and not a build-time copy

  The alternative was a script copying an extension's pages into `docs/` before
  compile. That makes the *repository* the thing that varies: `docs/` in git
  either carries pages a core distribution must not serve, or carries nav
  entries pointing at files that are not there, and the guardrails that walk
  `docs/` both ways have to be taught which is which.

  Embedding each manual in its own module moves the variation to where it
  belongs. A core image has no extension module, so it has no pages and no nav
  entry naming them: the manual it serves is complete, not pruned. Nobody has
  to remember to run a step.

  ## What is refused

  A slug the core manual already serves, and a mount other than the host's.
  Both are checked at boot by `Fountain.Extensions.validate!/0`, because two
  pages at one URL is a page nobody can reach and a page at a mount nothing
  routes is a page nobody can find.

  Nav sections merge by title: an extension section called `Integrations`
  appends its pages to the host's `Integrations` rather than opening a second
  section with the same name, so a page moved out of core stays where a reader
  last saw it.
  """

  alias Fountain.Extensions

  @core Fountain.Docs

  @doc "The core manual. Everything here composes around it."
  @spec core() :: module()
  def core, do: @core

  @doc """
  Every manual module this distribution serves: the core one first, then each
  installed extension's, in configured order.
  """
  @spec manuals() :: [module()]
  def manuals, do: [@core | extension_manuals()]

  @doc "Just the installed extensions' manual modules."
  @spec extension_manuals() :: [module()]
  def extension_manuals, do: extension_manuals(Extensions.installed())

  @doc "See `extension_manuals/0`. Takes the list, so a test can supply one."
  @spec extension_manuals([Extensions.t()]) :: [module()]
  def extension_manuals(modules) when is_list(modules) do
    modules
    |> Enum.map(& &1.docs())
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Fetch a page by slug, core first.

  Core wins a collision, and `validate!/0` refuses one at boot, so the order
  here is belt to that brace rather than a policy of its own.
  """
  @spec get(String.t()) :: {:ok, %{title: String.t(), body: String.t()}} | :error
  def get(slug) when is_binary(slug) do
    Enum.reduce_while(manuals(), :error, fn manual, :error ->
      case manual.get(slug) do
        {:ok, _page} = found -> {:halt, found}
        :error -> {:cont, :error}
      end
    end)
  end

  @doc "Every slug this distribution serves."
  @spec slugs() :: [String.t()]
  def slugs, do: manuals() |> Enum.flat_map(& &1.slugs()) |> Enum.uniq()

  @doc """
  The sidebar, with each extension's sections merged into the host's by title.

  A section an extension shares a title with gains its pages at the end of that
  section; a section title the host does not have becomes a new section after
  the host's own. Bare pages (a nav entry that is not a section) append at the
  end, which is where a top-level page from an extension reads least oddly.
  """
  @spec nav() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
  def nav do
    Enum.reduce(extension_manuals(), @core.nav(), &merge_nav(&2, &1.nav()))
  end

  defp merge_nav(base, additions) do
    Enum.reduce(additions, base, fn
      {section, children}, acc when is_list(children) ->
        if Enum.any?(acc, &match?({^section, existing} when is_list(existing), &1)) do
          Enum.map(acc, fn
            {^section, existing} when is_list(existing) -> {section, existing ++ children}
            other -> other
          end)
        else
          acc ++ [{section, children}]
        end

      page, acc ->
        acc ++ [page]
    end)
  end

  @doc """
  The served path for a slug.

  Every manual shares the host's mount — `validate!/0` refuses one that does
  not — so the core module's arithmetic is right for an extension's slug too.
  """
  @spec path_for_slug(String.t()) :: String.t()
  defdelegate path_for_slug(slug), to: @core

  @doc """
  The host's mount, `/docs`.

  Part of what makes this module shaped like a `Managoat.Docs` instance, so
  `Managoat.Docs.Checks` can be pointed at the merged manual and check a
  bundled distribution's links the same way it checks a core one's.
  """
  @spec mount() :: String.t()
  defdelegate mount, to: @core

  @doc "Every manual's search-index entries, concatenated."
  @spec search_index() :: [
          %{title: String.t(), slug: String.t(), headings: [%{id: String.t(), text: String.t()}]}
        ]
  def search_index, do: manuals() |> Enum.flat_map(& &1.search_index())

  @doc """
  The merged search index, pre-encoded.

  Encoded once per distribution rather than per request: the layout inlines
  this on every `/docs` render, and the installed set cannot change while the
  node is up. `Fountain.Docs` pays this at compile time; a merged index cannot,
  so it is memoised in `:persistent_term` instead.
  """
  @spec search_index_json() :: String.t()
  def search_index_json do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        json = manuals() |> Enum.flat_map(& &1.search_index()) |> Jason.encode!()
        :persistent_term.put(__MODULE__, json)
        json

      json ->
        json
    end
  end

  @doc """
  Drop the memoised search index.

  Only tests need this: the installed set is fixed for the life of a node, so
  nothing in production ever invalidates it.
  """
  @spec reset_search_index() :: :ok
  def reset_search_index do
    :persistent_term.erase(__MODULE__)
    :ok
  end

  ## ─── Validation, called from Fountain.Extensions ─────────────────────────

  @doc """
  Check one extension's manual against the core one.

  Returns `:ok` or `{:error, message}`. Separate from `Fountain.Extensions` so
  the manual's rules live beside the merge that depends on them.
  """
  @spec validate(Extensions.t()) :: :ok | {:error, String.t()}
  def validate(extension) do
    case extension.docs() do
      nil ->
        :ok

      manual when is_atom(manual) ->
        with :ok <- check_loaded(extension, manual),
             :ok <- check_mount(extension, manual) do
          check_slugs(extension, manual)
        end

      other ->
        {:error,
         "#{inspect(extension)} docs/0 must return a module or nil, got #{inspect(other)}"}
    end
  end

  defp check_loaded(extension, manual) do
    if Code.ensure_loaded?(manual) and function_exported?(manual, :slugs, 0) do
      :ok
    else
      {:error,
       "#{inspect(extension)} docs/0 returns #{inspect(manual)}, which is not a " <>
         "`use Managoat.Docs` module"}
    end
  end

  # `path_for_slug("")` is the mount itself, which is the cheapest way to ask a
  # generated module what it was mounted at without reaching into its
  # attributes.
  defp check_mount(extension, manual) do
    core_mount = @core.path_for_slug("")
    mount = manual.path_for_slug("")

    if mount == core_mount do
      :ok
    else
      {:error,
       "#{inspect(extension)} mounts its manual at #{inspect(mount)}, but the host " <>
         "serves #{inspect(core_mount)}; a page at another mount is a page nothing routes"}
    end
  end

  defp check_slugs(extension, manual) do
    core_slugs = MapSet.new(@core.slugs())

    case manual.slugs() |> Enum.filter(&MapSet.member?(core_slugs, &1)) |> Enum.sort() do
      [] ->
        :ok

      clashing ->
        {:error,
         "#{inspect(extension)} serves manual pages the core manual already serves: " <>
           Enum.join(clashing, ", ")}
    end
  end
end
