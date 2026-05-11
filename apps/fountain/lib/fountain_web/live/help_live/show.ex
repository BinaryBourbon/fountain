defmodule FountainWeb.HelpLive.Show do
  @moduledoc """
  In-app docs. Each topic is a markdown file under `priv/help/<slug>.md`,
  rendered via Earmark. Default topic is `quickstart`. The `/api/docs`
  Swagger UI is linked out separately as the API reference.

  Topic order + display names are hard-coded here so the nav stays
  curated rather than just listing whatever happens to be in the
  directory.
  """

  use FountainWeb, :live_view

  @topics [
    {"quickstart", "Quickstart"},
    {"agents", "Agents"},
    {"environments", "Environments"},
    {"vaults", "Vaults"},
    {"manifest", "Manifest"},
    {"spawning", "Spawning sub-agents"},
    {"api", "API reference"},
    {"for-llms", "For LLMs"},
    {"runbook", "Operating"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :topics, @topics)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    slug = params["topic"] || "quickstart"
    topic = Enum.find(@topics, fn {s, _} -> s == slug end)

    case topic do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "No such help topic: #{slug}")
         |> push_navigate(to: ~p"/help")}

      {slug, title} ->
        body = load_topic(slug)

        {:noreply,
         socket
         |> assign(:slug, slug)
         |> assign(:title, title)
         |> assign(:body_html, render_markdown(body))
         |> assign(:page_title, "Help · " <> title)}
    end
  end

  defp load_topic(slug) do
    path = Path.join([:code.priv_dir(:fountain) |> to_string(), "help", slug <> ".md"])

    case File.read(path) do
      {:ok, body} -> body
      {:error, _} -> "# Topic not found\n\nNo content at `#{path}`."
    end
  end

  defp render_markdown(text) do
    case Earmark.as_html(text, compact_output: true, smartypants: false) do
      {:ok, html, _} -> html
      {:error, html, _} -> html
      _ -> Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6">
      <aside class="w-48 shrink-0">
        <div class="text-[10px] uppercase tracking-wider text-zinc-400 font-medium mb-2 px-2">
          Help topics
        </div>
        <nav class="space-y-1">
          <%= for {slug, title} <- @topics do %>
            <.link
              navigate={~p"/help/#{slug}"}
              class={[
                "block rounded px-3 py-1.5 text-sm hover:bg-zinc-100",
                @slug == slug && "bg-zinc-100 font-medium",
                @slug != slug && "text-zinc-600"
              ]}
            >
              {title}
            </.link>
          <% end %>
          <a
            href="/api/docs"
            target="_blank"
            class="block rounded px-3 py-1.5 text-sm hover:bg-zinc-100 text-zinc-600"
          >
            API reference (Swagger) ↗
          </a>
          <a
            href="/llms.txt"
            target="_blank"
            class="block rounded px-3 py-1.5 text-sm hover:bg-zinc-100 text-zinc-600"
          >
            For LLMs (/llms.txt) ↗
          </a>
        </nav>
      </aside>

      <article class="flex-1 max-w-3xl bg-white border border-zinc-200 rounded-lg shadow-sm p-8">
        <div class="prose prose-zinc max-w-none prose-headings:font-semibold prose-headings:tracking-tight prose-pre:bg-zinc-900 prose-pre:text-zinc-100 prose-pre:text-xs prose-code:text-zinc-800 prose-code:bg-zinc-100 prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:before:content-none prose-code:after:content-none prose-a:text-blue-600">
          {Phoenix.HTML.raw(@body_html)}
        </div>
      </article>
    </div>
    """
  end
end
