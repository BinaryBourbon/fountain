defmodule FountainWeb.LlmsController do
  @moduledoc """
  LLM-discovery surface. Implements the llms.txt convention
  (https://llmstxt.org/) plus an external `SKILL.md` for Claude Code and
  similar agentic IDEs.

  Three endpoints:

    * `GET /llms.txt`      — short index pointing at the bits an LLM needs
    * `GET /llms-full.txt` — every help doc and the external skill concatenated
    * `GET /skill`         — the external `SKILL.md` only, drop-in for `~/.claude/skills/fountain/`

  All three are public, plain-text, no auth. The base URL embedded in the
  output is `Application.get_env(:fountain, :public_url)` so a self-hosted
  instance points at itself.
  """

  use FountainWeb, :controller

  # Topic order mirrors FountainWeb.HelpLive.Show — keep them in sync so the
  # bundled doc reads the same as the in-app nav.
  @help_topics [
    {"quickstart", "Quickstart"},
    {"agents", "Agents"},
    {"environments", "Environments"},
    {"vaults", "Vaults"},
    {"manifest", "Manifest"},
    {"spawning", "Spawning sub-agents"},
    {"api", "API reference"},
    {"secrets-managers", "Secrets managers"},
    {"for-llms", "For LLMs"},
    {"runbook", "Operating"}
  ]

  def index(conn, _params) do
    send_text(conn, render_index(base_url()))
  end

  def full(conn, _params) do
    send_text(conn, render_full(base_url()))
  end

  def skill(conn, _params) do
    send_text(conn, read_skill())
  end

  ## ─── Rendering ────────────────────────────────────────────────────────────

  defp render_index(base) do
    """
    # Fountain

    > Fountain is a multi-tenant service for running sandboxed coding agents. It provisions an isolated sprite per conversation, mounts a preconfigured environment (packages, repos, env vars, MCP servers, skills), and runs the agent CLI — claude, codex, gemini, or opencode — inside. Use it to delegate, fan out, or parallelize coding agents from your own scripts, CI, or IDE.

    The four primitives:

    - **Environment** — sandbox shape (apt packages, env vars, repos to clone, networking allowlist, setup script)
    - **Vault** — free-floating bag of encrypted secret overrides, picked per-conversation; layered over the env's secrets
    - **Agent** — named runtime config (runtime + model + system prompt + skills + MCP servers + an environment)
    - **Conversation** — one running instance of an agent inside a freshly provisioned sprite, streamable over SSE

    Public instance: <https://founta.inevitable.fyi>. Source: <https://github.com/BinaryBourbon/fountain>.

    ## Get started

    - [Quickstart](#{base}/help/quickstart): five minutes from install to first conversation
    - [CLI install (Homebrew)](https://github.com/BinaryBourbon/homebrew-tap): `brew install BinaryBourbon/tap/fountain`
    - [Example agent specs](https://github.com/jhgaylor/agent-specs): public manifest tree you can `fountain apply`

    ## Concepts

    - [Agents](#{base}/help/agents): runtime, model, skills, MCP server config
    - [Environments](#{base}/help/environments): sandbox shape, packages, repositories, networking
    - [Vaults](#{base}/help/vaults): per-conversation credential overrides
    - [Manifest](#{base}/help/manifest): `fountain apply -f fountain.yml` declarative format
    - [Spawning sub-agents](#{base}/help/spawning): how agents inside sprites call back to spawn more
    - [Secrets managers](#{base}/help/secrets-managers): 1Password, Bitwarden, Infisical apply-time resolution
    - [Operator runbook](#{base}/help/runbook): incident response, key rotation, orphaned sprite cleanup

    ## API

    - [OpenAPI 3 spec](#{base}/api/openapi.json): machine-readable contract
    - [Swagger UI](#{base}/api/docs): interactive try-it, click "Authorize" to set your bearer token
    - [Endpoint summary](#{base}/help/api): summary table and response envelope

    ## For LLMs

    - [/llms-full.txt](#{base}/llms-full.txt): everything in this index expanded and inlined as one document
    - [/skill](#{base}/skill): a `SKILL.md` you can drop into `~/.claude/skills/fountain/` to teach Claude Code (or any agent that loads SKILL.md) how to use Fountain

    Install the skill:

    ```sh
    mkdir -p ~/.claude/skills/fountain
    curl -fsSL #{base}/skill > ~/.claude/skills/fountain/SKILL.md
    ```

    ## Optional

    - [GitHub repo](https://github.com/BinaryBourbon/fountain): source, releases, issues
    - [Homebrew tap](https://github.com/BinaryBourbon/homebrew-tap): pinned binaries
    - [llms.txt spec](https://llmstxt.org/): the convention this file follows
    """
  end

  defp render_full(base) do
    [
      render_index(base),
      "\n\n---\n\n# Full documentation\n\n",
      "Everything below is the in-app help corpus inlined for LLMs that prefer a single document over crawling links.\n\n",
      bundled_help_sections(),
      "\n\n---\n\n# SKILL.md (external)\n\n",
      "The block below is also served at `#{base}/skill`. Drop it into `~/.claude/skills/fountain/SKILL.md` (or the equivalent for your agent) so the agent has the full operational knowledge below loaded as a skill.\n\n",
      "```markdown\n",
      read_skill(),
      "\n```\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp bundled_help_sections do
    Enum.map(@help_topics, fn {slug, title} ->
      body = read_help(slug)
      ["\n\n## ", title, " (`/help/", slug, "`)\n\n", body, "\n"]
    end)
  end

  ## ─── File reads ───────────────────────────────────────────────────────────

  defp read_help(slug) do
    path = Path.join([priv_dir(), "help", slug <> ".md"])

    case File.read(path) do
      {:ok, body} -> body
      {:error, _} -> "_(missing: " <> slug <> ".md)_"
    end
  end

  defp read_skill do
    path = Path.join([priv_dir(), "external_skills", "fountain", "SKILL.md"])

    case File.read(path) do
      {:ok, body} ->
        body

      {:error, _} ->
        "# fountain skill\n\n_(missing — bundle did not include external_skills/fountain/SKILL.md)_\n"
    end
  end

  defp priv_dir, do: :fountain |> :code.priv_dir() |> to_string()

  ## ─── Helpers ──────────────────────────────────────────────────────────────

  defp base_url do
    Application.get_env(:fountain, :public_url, "https://founta.inevitable.fyi")
    |> String.trim_trailing("/")
  end

  defp send_text(conn, body) do
    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(200, body)
  end
end
