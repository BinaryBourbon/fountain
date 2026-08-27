defmodule FountainWeb.MarketingHTML do
  @moduledoc false
  use FountainWeb, :html
  import FountainWeb.MarketingIcons, only: [mark: 1]

  embed_templates "marketing_html/*"

  @doc "The SDK call on the homepage, kept out of the template so its braces are not HEEx."
  def sdk_example do
    """
    import { Fountain } from "@agentshit/fountain-sdk";

    const fountain = new Fountain(); // FOUNTAIN_API_KEY

    const run = await fountain.run(
      "Fix the failing test and open a PR",
      { agent: "reviewer" }
    );

    console.log(run.output);\
    """
  end

  @doc "Whether the pricing section renders at all: only where the deployment bills."
  def pricing?, do: Fountain.Credits.enabled?()

  @doc "The opening credit a new account gets, and how long it lasts."
  def opening_credit do
    cfg = Application.get_env(:fountain, :credits, [])

    {Fountain.Credits.format_cents(Keyword.get(cfg, :opening_cents, 500)),
     Keyword.get(cfg, :opening_days, 14)}
  end

  @doc "The concurrency rule (ADR 0031), read from the same settings Quotas enforces."
  def cap_rule do
    %{reserve_cents: reserve, cap_floor: floor, cap_ceiling: ceiling} = Fountain.Quotas.settings()
    {Fountain.Credits.format_cents(reserve), floor, ceiling}
  end

  # The customer prices, read from the same card the ledger burns at, so the
  # page cannot quote a number the meter does not charge (ADR 0030).
  def turn_hour_price, do: Fountain.Credits.format_cents(Fountain.Credits.price_card().turn_hour)

  def credit_packs do
    Enum.map_join(Fountain.Credits.packs(), ", ", &Fountain.Credits.format_cents/1)
  end

  # Nil when this deployment charges nothing for a line, so the page says
  # nothing about it rather than quoting $0.
  def rent_line do
    card = Fountain.Credits.price_card()

    parts =
      [
        card.number_month &&
          "a phone number #{Fountain.Credits.format_cents(card.number_month)} a month",
        card.inbox_month &&
          "an email inbox #{Fountain.Credits.format_cents(card.inbox_month)} a month"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, ", ")
  end

  def message_line do
    card = Fountain.Credits.price_card()

    parts =
      [
        card.email_message && "#{Fountain.Credits.format_cents(card.email_message)} an email",
        card.sms_message &&
          "#{Fountain.Credits.format_cents(card.sms_message)} a text, sent or received"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, " and ")
  end

  ## /integrations
  #
  # The page is data first: the protocols Fountain speaks, what already speaks
  # each one, and one snippet for each shape of builder. Each entry links a
  # page of the manual, and the controller test checks every such link
  # resolves, so a renamed docs page fails here rather than on the site.

  @doc "The protocols Fountain answers, in the order the page shows them."
  def protocols do
    [
      %{
        id: "agui",
        name: "AG-UI",
        long: "Agent-User Interaction Protocol",
        surface: "POST /api/agui/:agent_id",
        direction: "An AG-UI host drives a Fountain agent.",
        pitch:
          "The open protocol between an agent and a front end, from CopilotKit. " <>
            "Fountain answers a RunAgentInput with the standard event stream, so a " <>
            "Fountain agent takes a seat next to a LangGraph or CrewAI one with no " <>
            "adapter. Pass the host's tools and a call comes back as TOOL_CALL events. " <>
            "One thread binds to one conversation, and the sandbox is the memory.",
        docs: "/docs/integrations/openbot",
        docs_label: "OpenBot and AG-UI",
        works_with: [
          %{
            name: "OpenBot",
            slug: nil,
            note: "CopilotKit's agent platform; a coworker per agent, verified"
          },
          %{
            name: "CopilotKit",
            slug: nil,
            note: "React, Angular and React Native apps, via HttpAgent"
          },
          %{name: "Slack", slug: "slack", note: "CopilotKit's chat-platform clients"},
          %{name: "LangGraph", slug: "langgraph", note: "a peer in the same roster"},
          %{name: "CrewAI", slug: "crewai", note: "a peer in the same roster"},
          %{name: "Mastra", slug: nil, note: "a peer in the same roster"},
          %{name: "Pydantic AI", slug: "pydantic", note: "a peer in the same roster"},
          %{name: "Google ADK", slug: "google", note: "a peer in the same roster"}
        ]
      },
      %{
        id: "acp",
        name: "ACP",
        long: "Agent Client Protocol",
        surface: "fountain acp --agent <name>",
        direction: "An editor or chat harness spawns the CLI and drives a conversation.",
        pitch:
          "Zed's editor protocol for coding agents. Fountain is an ACP client of the " <>
            "agents it runs in sandboxes and an ACP agent for the editor in front of you, " <>
            "so the same block vocabulary flows through untranslated. Close the laptop " <>
            "mid-turn; the turn continues on the sandbox and replays when you reopen.",
        docs: "/docs/integrations/editors",
        docs_label: "Editors over ACP",
        works_with: [
          %{name: "Zed", slug: "zedindustries", note: "an agent_servers entry, verified"},
          %{
            name: "JetBrains IDEs",
            slug: "jetbrains",
            note: "AI Assistant's acp.json, no subscription needed"
          },
          %{name: "Neovim", slug: "neovim", note: "CodeCompanion, avante"},
          %{name: "Emacs", slug: "gnuemacs", note: "agent-shell"},
          %{name: "VS Code", slug: nil, note: "the ACP client extensions"},
          %{name: "Obsidian", slug: "obsidian", note: "the Agent Client plugins"},
          %{name: "Jupyter", slug: "jupyter", note: "agent-client-kernel"},
          %{
            name: "OpenClaw",
            slug: nil,
            note: "its acpx plugin, verified, from Telegram, Discord, Slack, Signal or iMessage"
          },
          %{name: "Discord", slug: "discord", note: "the community ACP bridges, and Telegram's"},
          %{
            name: "Vercel AI SDK",
            slug: "vercel",
            note: "the community acp-ai-provider, an ACP agent as a LanguageModel"
          }
        ]
      },
      %{
        id: "openai",
        name: "OpenAI-compatible",
        long: "Chat completions, where the model is an agent",
        surface: "POST /v1/chat/completions",
        direction: "Any client or gateway with a base-URL field drives a Fountain agent.",
        pitch:
          "The request shape every gateway and every chat client already speaks. Point " <>
            "one at your instance with an API key, and GET /v1/models fills its picker with " <>
            "your agents. Your tools come back as tool_calls, so a Fountain agent sits " <>
            "inside a LangChain loop or a Deep Agents plan as a subagent. A thread key " <>
            "binds each chat to one sandbox. Alpha, behind a flag; ask and it is on.",
        docs: "/docs/integrations/openai-compatible",
        docs_label: "The OpenAI-compatible API",
        works_with: [
          %{name: "Open WebUI", slug: nil, note: "a base URL and a key"},
          %{name: "LibreChat", slug: nil, note: "a custom endpoint"},
          %{
            name: "LiteLLM",
            slug: nil,
            note: "a route, verified against the example in the repo"
          },
          %{name: "Portkey", slug: nil, note: "a gateway route"},
          %{name: "Kong AI Gateway", slug: "kong", note: "a gateway route"},
          %{name: "Cloudflare AI Gateway", slug: "cloudflare", note: "a gateway route"},
          %{name: "OpenAI SDKs", slug: "openai", note: "base_url, in any language"},
          %{name: "Vercel AI SDK", slug: "vercel", note: "createOpenAICompatible"},
          %{
            name: "LangChain",
            slug: "langchain",
            note: "as a model, a tool, or a Deep Agents subagent"
          },
          %{name: "LangGraph", slug: "langgraph", note: "one thread_id is one sandbox per agent"},
          %{name: "Continue", slug: nil, note: "apiBase on an openai provider"},
          %{name: "Cline", slug: "cline", note: "its OpenAI Compatible provider"},
          %{name: "Aider", slug: nil, note: "OPENAI_API_BASE"},
          %{name: "Dify", slug: "dify", note: "the OpenAI-API-compatible plugin"},
          %{name: "Raycast", slug: "raycast", note: "a custom provider"},
          %{name: "curl", slug: "curl", note: "one request"}
        ]
      },
      %{
        id: "mcp",
        name: "MCP",
        long: "Model Context Protocol, both ways",
        surface: "Any MCP server, on any agent",
        direction: "Agents call the servers you name; Fountain hosts four of its own.",
        pitch:
          "An agent's config lists the MCP servers it may call, and Fountain passes " <>
            "the declaration through and curates nothing. A Gmail Connection holds the " <>
            "OAuth grant on the server, so an inbox arrives as tools with no token in " <>
            "the prompt. Fountain also serves MCP to its own sandboxes: a teammate to " <>
            "message, an email address and a phone number, a Buzz channel, a mailbox.",
        docs: "/docs/catalog/mcp-servers",
        docs_label: "The MCP servers Fountain hosts",
        works_with: [
          %{name: "Gmail", slug: "gmail", note: "a Connection, then the inbox as seven tools"},
          %{
            name: "fountain-team",
            slug: nil,
            note: "message a teammate, from inside the sandbox"
          },
          %{name: "fountain-comms", slug: nil, note: "a teammate's own email and phone"},
          %{name: "fountain-buzz", slug: nil, note: "post to a Buzz channel as the agent"},
          %{
            name: "Any stdio or HTTP server",
            slug: nil,
            note: "named on the agent, run in its sandbox"
          }
        ]
      },
      %{
        id: "api",
        name: "REST, SSE and webhooks",
        long: "Fountain's own API",
        surface: "/api, with a TypeScript SDK and a CLI",
        direction: "Your code drives everything the console can, and more.",
        pitch:
          "Everything above is a translation of this. Create a conversation, send a " <>
            "prompt, stream the turn as blocks the server has already parsed, or take a " <>
            "signed webhook when it ends. Sign in with Fountain gives a browser app of " <>
            "your own an OAuth flow whose tokens are ordinary API keys. The three apps " <>
            "this project ships are built on exactly this and nothing private: static " <>
            "files, the SDK, your key.",
        docs: "/docs/api",
        docs_label: "The API reference",
        works_with: [
          %{
            name: "Conversations",
            slug: nil,
            note: "the chat app we ship, static files on the SDK"
          },
          %{name: "Team", slug: nil, note: "the team messenger, on the same public API"},
          %{name: "Workbench", slug: nil, note: "the shared engineering workbench"},
          %{name: "TypeScript", slug: "typescript", note: "@agentshit/fountain-sdk on npm"},
          %{name: "Go", slug: "go", note: "the fountain CLI, and its source"},
          %{
            name: "GitHub Actions",
            slug: "githubactions",
            note: "a webhook, or the CLI in a step"
          },
          %{name: "React", slug: "react", note: "a static app on Sign in with Fountain"},
          %{name: "Claude Code", slug: "claudecode", note: "the /skill file teaches it the API"},
          %{name: "Cursor", slug: "cursor", note: "the same skill, and /llms.txt"},
          %{
            name: "Hermes Agent",
            slug: nil,
            note: "the plugin this repo ships: fountain_run and six more"
          },
          %{name: "curl", slug: "curl", note: "everything the SDK does"}
        ]
      },
      %{
        id: "nostr",
        name: "Nostr",
        long: "Buzz, the other direction",
        surface: "POST /api/buzz/agents",
        direction: "Outbound. Fountain hosts the agent and shows up on the relay.",
        pitch:
          "Buzz is an agent workspace on Nostr, and on the desktop an agent's body runs " <>
            "on your laptop. Bind its identity to a Fountain agent instead and the body " <>
            "runs here: it holds presence on the relay, answers a mention from a sandbox, " <>
            "and its key stays in a vault Fountain signs with.",
        docs: "/docs/integrations/buzz",
        docs_label: "Buzz on Fountain",
        works_with: [
          %{name: "Buzz", slug: nil, note: "provision from the desktop, or the API"},
          %{name: "Nostr relays", slug: nil, note: "group channels, presence, mentions"}
        ]
      }
    ]
  end

  @doc "What runs inside a conversation, grouped for the page's second section."
  def inside do
    [
      %{
        title: "Runtimes",
        blurb:
          "The coding agent the sandbox runs. All four speak ACP to Fountain, so every surface above sees one shape.",
        items: [
          %{name: "Claude Code", slug: "claudecode"},
          %{name: "Codex", slug: "openai"},
          %{name: "Gemini CLI", slug: "googlegemini"},
          %{name: "OpenCode", slug: "opencode"}
        ]
      },
      %{
        title: "Models",
        blurb:
          "Bring your own key. Inference bills your account; Fountain never marks up a token.",
        items: [
          %{name: "Anthropic", slug: "anthropic"},
          %{name: "OpenAI", slug: "openai"},
          %{name: "Google Gemini", slug: "googlegemini"},
          %{name: "Claude subscription", slug: "claude"}
        ]
      },
      %{
        title: "Sandboxes",
        blurb:
          "Where the agent runs. A hosted provider, or a runner on hardware you own that dials out over WebSocket.",
        items: [
          %{name: "Sprites", slug: nil},
          %{name: "E2B", slug: nil},
          %{name: "Daytona", slug: nil},
          %{name: "Your own machine", slug: nil}
        ]
      },
      %{
        title: "Chat surfaces",
        blurb:
          "Where a person talks to the agent, through OpenClaw or Hermes on one side or a Buzz channel on the other.",
        items: [
          %{name: "Telegram", slug: "telegram"},
          %{name: "Discord", slug: "discord"},
          %{name: "Slack", slug: "slack"},
          %{name: "Signal", slug: "signal"}
        ]
      }
    ]
  end

  @doc """
  Services the egress broker ships a credential preset for, read from the same
  catalog the console offers, so the page cannot name one the broker lacks.
  """
  def brokered_services do
    Fountain.SecretBindings.Catalog.presets()
    |> Enum.filter(& &1.usable)
    |> Enum.map(fn svc -> %{name: svc.name, slug: broker_slug(svc.id)} end)
  end

  @broker_slugs %{
    "anthropic" => "anthropic",
    "cloudflare" => "cloudflare",
    "datadog" => "datadog",
    "discord" => "discord",
    "github" => "github",
    "gitlab" => "gitlab",
    "gemini" => "googlegemini",
    "linear" => "linear",
    "notion" => "notion",
    "openai" => "openai",
    "pagerduty" => "pagerduty",
    "sentry" => "sentry",
    "shopify" => "shopify",
    "slack" => "slack",
    "stripe" => "stripe",
    "supabase" => "supabase",
    "telegram" => "telegram",
    "vercel" => "vercel"
  }

  defp broker_slug(id), do: Map.get(@broker_slugs, id)

  @doc "One snippet for each shape of builder, kept here so braces are not HEEx."
  def scenarios do
    [
      %{
        id: "react",
        have: "A React app",
        want: "An agent in the product, with a sandbox of its own behind the chat.",
        how: "Point CopilotKit's AG-UI client at the agent's endpoint. No adapter, no proxy.",
        lang: "ts",
        docs: "/docs/integrations/openbot",
        code: """
        import { HttpAgent } from "@ag-ui/client";

        const reviewer = new HttpAgent({
          url: "https://managoat.com/api/agui/<agent_id>",
          headers: { Authorization: "Bearer ftn_..." },
        });
        """
      },
      %{
        id: "editor",
        have: "An editor",
        want: "A thread in Zed that runs on a machine that is not yours.",
        how: "One agent_servers entry. Credentials come from fountain auth login.",
        lang: "json",
        docs: "/docs/integrations/editors",
        code: """
        "agent_servers": {
          "Fountain: reviewer": {
            "command": "fountain",
            "args": ["acp", "--agent", "reviewer", "--permission", "ask"]
          }
        }
        """
      },
      %{
        id: "chat",
        have: "A chat UI with a base-URL field",
        want: "Your agents in its model picker.",
        how: "Base URL, key, and a thread header so each chat keeps one sandbox.",
        lang: "bash",
        docs: "/docs/integrations/openai-compatible",
        code: """
        curl https://managoat.com/v1/chat/completions \\
          -H "Authorization: Bearer ftn_..." \\
          -H "X-Fountain-Thread: prs-2026-08-25" \\
          -d '{"model": "reviewer", "stream": true,
               "messages": [{"role": "user", "content": "Review the open PRs."}]}'
        """
      },
      %{
        id: "assistant",
        have: "A personal assistant",
        want:
          "OpenClaw or Hermes hands a task to a Fountain agent from Telegram, Discord or Slack.",
        how:
          "OpenClaw's acpx plugin spawns fountain acp. Hermes installs the plugin this repo ships.",
        lang: "bash",
        docs: "/docs/integrations/openclaw",
        code: """
        # OpenClaw: an ACP backend
        openclaw plugins install @openclaw/acpx

        # Hermes Agent: fountain_run and six siblings
        hermes plugins install BinaryBourbon/fountain/integrations/hermes/fountain --enable
        """
      },
      %{
        id: "pipeline",
        have: "A pipeline",
        want: "Start a run from CI, hear about it when it ends.",
        how: "The CLI in a step, a signed webhook to a URL you own.",
        lang: "bash",
        docs: "/docs/reference/webhooks",
        code: """
        fountain conversations create --agent reviewer \\
          --prompt "Review PR #$PR" --external-id "pr-$PR"

        fountain webhooks create https://example.com/hooks/fountain \\
          --event conversation.turn.done --event conversation.turn.failed
        """
      },
      %{
        id: "product",
        have: "Your own product",
        want: "A roster of agents and threads, under your login, on your origin.",
        how: "The SDK for the calls, Sign in with Fountain for the user, one static app.",
        lang: "ts",
        docs: "/docs/build",
        code: """
        import { Fountain } from "@agentshit/fountain-sdk";

        const fountain = new Fountain({ apiKey: token }); // from the OAuth flow
        const conv = await fountain.conversations.create({ agent: "reviewer" });
        for await (const block of fountain.conversations.stream(conv.id)) render(block);
        """
      }
    ]
  end

  ## /built-with
  #
  # The apps built on the API, grouped by who they are for. Every one is a
  # real deployment against the hosted instance, and every one is open source,
  # so a card carries two links and the page carries no claim that cannot be
  # clicked. The controller test asserts both are absolute and that no app is
  # listed twice.
  #
  # The first group is the three this project builds itself, and they lead
  # every page that shows the roster. An app in it carries a `:flagship` key
  # holding the two lines the featured cards add: what it is like, and who it
  # is for. That key is what `flagship_apps/0` selects on, so the tier is a
  # property of the entry rather than a second list to keep in step.

  @doc "The applications built on the API, in the order and grouping the page shows."
  def built_apps do
    [
      %{
        id: "flagship",
        title: "The three we build ourselves",
        blurb:
          "Fountain's own UI is a console: accounts, keys, agents, environments, audit. The apps you actually work in are these, on their own origins, built on the same public API as everything below. Open one, point it at your instance, sign in.",
        apps: [
          %{
            id: "fountain-conversations",
            glyph: "\u{1F9F5}",
            name: "Conversations",
            host: "jakegaylor.com/fountain-conversations",
            url: "https://jakegaylor.com/fountain-conversations/",
            source: "https://github.com/jhgaylor/fountain-conversations",
            blurb:
              "Start a run, watch the agent work turn by turn, and drive it. Chat, timeline and raw views of the same conversation, plus the machine it shares with its siblings.",
            shows: "the event stream as blocks, and one sandbox behind many conversations",
            flagship: %{
              like: "ChatGPT, except the model has a real computer and you can watch it use one.",
              who: "Open this one first. It is the whole platform with a face on it."
            }
          },
          %{
            id: "fountain-team",
            glyph: "\u{1F465}",
            name: "Team",
            host: "jakegaylor.com/fountain-team",
            url: "https://jakegaylor.com/fountain-team/",
            source: "https://github.com/jhgaylor/fountain-team",
            blurb:
              "Your agents as teammates in a messaging app. Roster on the left, thread on the right, routines on a schedule, images and search. Enter to send.",
            shows: "the team API, SSE streaming, schedules, usage",
            flagship: %{
              like:
                "A group chat whose contacts are bots you made, one click each, faces and all.",
              who: "For anyone who would rather text a teammate than fill in a form."
            }
          },
          %{
            id: "fountain-workbench",
            glyph: "\u{1F9F0}",
            name: "Workbench",
            host: "workbench.inevitable.fyi",
            url: "https://workbench.inevitable.fyi",
            source: "https://github.com/jhgaylor/fountain-workbench",
            blurb:
              "A dev workstation the team shares. A project is an environment and a vault, work items live in it, and putting a teammate on one is a first prompt rather than four steps of setup.",
            shows: "projects over environments and vaults, agents as staff",
            flagship: %{
              like:
                "Multiplayer engineering: one board of work items, and staff you put on them by typing.",
              who:
                "For a team that wants the same projects, the same agents and one place to watch."
            }
          }
        ]
      },
      %{
        id: "everyone",
        title: "For everyone",
        blurb:
          "No agent, no sandbox and no prompt box on screen. The product is the document, the chart or the text message.",
        apps: [
          %{
            id: "briefing-room",
            glyph: "\u{1F4F0}",
            name: "Briefing Room",
            host: "briefs.inevitable.fyi",
            url: "https://briefs.inevitable.fyi",
            source: "https://github.com/jhgaylor/briefing-room",
            blurb:
              "Say what you need to understand and why. A researcher with its own computer reads real sources and hands back a clean, cited brief. A document, not a chat.",
            shows: "web research behind a UI with none of the AI-chat furniture"
          },
          %{
            id: "table-talk",
            glyph: "\u{1F4CA}",
            name: "Table Talk",
            host: "tables.inevitable.fyi",
            url: "https://tables.inevitable.fyi",
            source: "https://github.com/jhgaylor/table-talk",
            blurb:
              "Drop a CSV in. An analyst runs Python on its sandbox and comes back with charts and plain-English findings. Then keep asking questions of your data.",
            shows: "a real computer as the engine under a zero-jargon UI"
          },
          %{
            id: "reflex",
            glyph: "\u{1F4AC}",
            name: "Reflex",
            host: "reflex.inevitable.fyi",
            url: "https://reflex.inevitable.fyi",
            source: "https://github.com/jhgaylor/reflex",
            blurb:
              "A personal assistant you text. It keeps a computer, your accounts and a memory, and it works while you do something else: books the dentist, sweeps the inbox at two, texts you when the tickets come back.",
            shows: "a persistent teammate, its own phone number, and routines on a schedule"
          }
        ]
      },
      %{
        id: "engineers",
        title: "For engineers",
        blurb:
          "The sandbox is the point. Each of these hands an agent a checkout, a shell and a task list, then shows you the work.",
        apps: [
          %{
            id: "repo-sage",
            glyph: "\u{1F33F}",
            name: "Repo Sage",
            host: "reposage.inevitable.fyi",
            url: "https://reposage.inevitable.fyi",
            source: "https://github.com/jhgaylor/repo-sage",
            blurb:
              "Name any public GitHub repository. An agent clones it on its own machine and answers with file-and-line citations that link back to the source.",
            shows: "the sandbox as a workstation: clone, grep, read, cite"
          },
          %{
            id: "mission-control",
            glyph: "\u{1F680}",
            name: "Mission Control",
            host: "mission.inevitable.fyi",
            url: "https://mission.inevitable.fyi",
            source: "https://github.com/jhgaylor/mission-control",
            blurb:
              "Describe a mission. A coordinator plans it, you approve the plan, and the app starts one sandboxed agent per task. Watch the fleet work and take one report.",
            shows: "plan, approve, fan out, multiplex the streams, synthesize"
          },
          %{
            id: "dns-desk",
            glyph: "\u{1F5C2}\u{FE0F}",
            name: "DNS Desk",
            host: "jakegaylor.com/dns-desk",
            url: "https://jakegaylor.com/dns-desk/",
            source: "https://github.com/jhgaylor/dns-desk",
            blurb:
              "A DNS operator for your Cloudflare zones. Ask in plain words, read the plan as a diff, approve. The zone tables stay on screen while the agent does the work.",
            shows: "plan, approve, apply on a live system, with a vault as the blast radius"
          }
        ]
      },
      %{
        id: "infrastructure",
        title: "For infrastructure",
        blurb:
          "Nobody is watching these. A schedule wakes the agent, it decides whether anything needs doing, and most of the time the answer is no.",
        apps: [
          %{
            id: "watchtower",
            glyph: "\u{1F5FC}",
            name: "Watchtower",
            host: "watchtower.inevitable.fyi",
            url: "https://watchtower.inevitable.fyi",
            source: "https://github.com/jhgaylor/watchtower",
            blurb:
              "An SRE teammate on a cron: uptime, latency, TLS expiry and DNS for every site you name. When a tile turns red, ask it to investigate. It has real tools.",
            shows: "schedules as a product heartbeat, the conversation as the store"
          },
          %{
            id: "mend",
            glyph: "\u{1F526}",
            name: "Mend",
            host: "mend.inevitable.fyi",
            url: "https://mend.inevitable.fyi",
            source: "https://github.com/jhgaylor/mend",
            blurb:
              "What an audit finds across a repository's CI, manifests, Dockerfiles and cloud templates, and what an agent does once you hand it that tool. Mechanical fixes applied, judgement calls argued, one patch back.",
            shows:
              "a real CLI in the sandbox, and the restraint to leave the ambiguous ones alone"
          },
          %{
            id: "rounds",
            glyph: "\u{1F501}",
            name: "Rounds",
            host: "rounds.inevitable.fyi",
            url: "https://rounds.inevitable.fyi",
            source: "https://github.com/jhgaylor/rounds",
            blurb:
              "Dependabot for infrastructure config. Enrol a repository and it gets audited on a schedule; an agent fixes what it can verify and opens the pull request. Never twice for the same finding, never again for one you closed.",
            shows: "an unattended product, and an agent that knows when to do nothing"
          }
        ]
      },
      %{
        id: "ai-engineers",
        title: "For AI engineers",
        blurb: "Several agents at once, side by side, with the numbers underneath.",
        apps: [
          %{
            id: "arena",
            glyph: "\u{1F94A}",
            name: "Arena",
            host: "arena.inevitable.fyi",
            url: "https://arena.inevitable.fyi",
            source: "https://github.com/jhgaylor/arena",
            blurb:
              "One prompt, several brains, side by side. Blind columns, live streams, latency and token counts, and your vote on the scoreboard.",
            shows: "parallel conversations, the model catalog, per-turn usage"
          }
        ]
      }
    ]
  end

  @doc "Every app on /built-with, flattened. The count the page quotes comes from here."
  def built_apps_flat, do: Enum.flat_map(built_apps(), & &1.apps)

  @doc """
  The three applications this project builds itself, in the order every page
  shows them. Selected out of `built_apps/0` rather than restated, so a
  flagship card cannot drift from its roster entry.
  """
  def flagship_apps, do: Enum.filter(built_apps_flat(), &Map.has_key?(&1, :flagship))

  @doc "The group the flagship apps sit in, for the heading above their cards."
  def flagship_group, do: Enum.find(built_apps(), &(&1.id == "flagship"))

  @doc "The rest of the roster, which /built-with lists under the featured three."
  def other_app_groups, do: Enum.reject(built_apps(), &(&1.id == "flagship"))

  @doc "The rest of the roster, flattened, for the homepage's chip row."
  def other_apps_flat, do: Enum.flat_map(other_app_groups(), & &1.apps)

  ## /self-hosted

  @repo_url "https://github.com/BinaryBourbon/fountain"

  @doc "The project's repository. The self-hosted page links it from four places."
  def repo_url, do: @repo_url

  # The four apps /self-hosted leads with, chosen for four different shapes of
  # front door: an assistant you text, an analyst behind a file upload, an
  # unattended repair loop, and a fan-out. Selected from `built_apps/0` by id
  # rather than restated, so a card here cannot drift from /built-with, and an
  # app that is renamed or retired there raises at render instead of linking
  # nowhere. The flagship three are deliberately not here: the same page shows
  # them below the bring-up, as the front ends the reader gets rather than as
  # evidence that other people build on this.
  @showcase_ids ~w(reflex table-talk rounds mission-control)

  @doc """
  The applications /self-hosted shows above the bring-up. The page's claim is
  that an agent defined once gets hired by anything, and these are the anything.
  """
  def self_host_showcase do
    by_id = Map.new(built_apps_flat(), &{&1.id, &1})
    Enum.map(@showcase_ids, &Map.fetch!(by_id, &1))
  end

  @doc "How many applications the roster holds. Both marketing pages quote it."
  def built_app_count, do: length(built_apps_flat())

  @doc """
  The bring-up, verbatim from the deploy guide, so the page cannot drift into
  showing commands the manual does not. Kept out of the template because
  `$(...)` and `${...}` are not HEEx.
  """
  def compose_example do
    """
    git clone https://github.com/BinaryBourbon/fountain
    cd fountain

    cp .env.compose.example .env
    echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\\n')" >> .env
    echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\\n')" >> .env
    # ... and your sandbox provider token

    docker compose up -d\
    """
  end

  @doc """
  The three features the hosted platform rations, and what they cost on an
  instance of your own. The rows track `docs/reference/feature-status.md`; a
  feature that comes off that page comes off this one.
  """
  def rationed_features do
    [
      %{
        name: "Teammate email and phone",
        blurb: "An agent with its own inbox and its own number, that answers what arrives.",
        hosted: "Behind a flag. Ask us to turn it on for your account.",
        yours:
          "Set AGENTMAIL_API_KEY and AGENTPHONE_API_KEY, then add team_comms to FEATURE_FLAGS_ON.",
        docs: "/docs/catalog/mcp-servers/fountain-comms"
      },
      %{
        name: "OpenAI-compatible API",
        blurb:
          "Point anything that speaks chat completions at your instance, where the model is an agent.",
        hosted: "Behind a flag. Ask us to turn it on for your account.",
        yours: "Add openai_compat to FEATURE_FLAGS_ON.",
        docs: "/docs/integrations/openai-compatible"
      },
      %{
        name: "Brokered credentials",
        blurb:
          "The real token never enters the sandbox. The broker attaches it on the way out, and the transcript keeps a placeholder.",
        hosted: "Limited access. We enrol an account by hand.",
        yours: "Set BROKER_URL and BROKER_TOKEN, and list the tenants in BROKER_TENANTS.",
        docs: "/docs/concepts/secrets"
      }
    ]
  end

  @doc "What each licence lets you do, in the order that matters to somebody deciding."
  def licence_parts do
    [
      %{
        part: "The server",
        scope: "apps/fountain",
        licence: "AGPL-3.0-or-later",
        means:
          "Run it, change it, host it, charge for it. Offer a changed server to other people over a network and they have a right to your source."
      },
      %{
        part: "Credits and Stripe",
        scope: "ee/",
        licence: "Elastic 2.0",
        means:
          "Free to run in your own instance, and your changes stay yours. The one thing it forbids is selling this code to third parties as a hosted service."
      },
      %{
        part: "The CLI and the SDK",
        scope: "cli/, sdk/typescript",
        licence: "Apache-2.0",
        means:
          "Ship them inside a closed product. An application that calls your instance takes on no obligation at all."
      }
    ]
  end

  @doc "The four rungs of ownership, from the app down to the last vendor."
  def ownership_rungs do
    [
      %{
        step: "01",
        title: "The app",
        body:
          "Your container, your Postgres, your domain. Conversations, transcripts, audit rows and API keys live in a database you can open with psql."
      },
      %{
        step: "02",
        title: "The secrets",
        body:
          "Every tenant's env vars are encrypted with a key derived from a master key you generate. It is not in the database, which is also why a database backup on its own does not save you."
      },
      %{
        step: "03",
        title: "The machines",
        body:
          "A Mac mini, a home server or a GPU box becomes a sandbox backend with one daemon. It dials out and holds one connection. There is no inbound port to open and no credential to hand it."
      },
      %{
        step: "04",
        title: "The last vendor",
        body:
          "Server on your hardware, sandboxes on your machines, and no third-party account is left in the loop. Not a sandbox host's, and not ours."
      }
    ]
  end

  @doc """
  What self-hosting costs, said plainly. A page that sells an instance and
  hides the bill for it gets found out in week three.
  """
  def self_host_costs do
    [
      %{
        title: "A sandbox backend is somebody's service, unless you bring machines",
        body:
          "Sprites, E2B and Daytona are all hosted. Daytona you can run yourself, and your own runners need no vendor at all. Pick one before your first conversation, because without one every conversation fails.",
        docs: "/docs/integrations/runners",
        docs_label: "Runners on your own hardware"
      },
      %{
        title: "Email is a decision, not an optional extra",
        body:
          "Verification and password resets go through Resend, or an SMTP server of yours. So does anything a teammate sends. The compose defaults skip delivery so the first account can register, and that default is for day one only.",
        docs: "/docs/guides/operate/email",
        docs_label: "Configure email"
      },
      %{
        title: "The master key is yours to lose",
        body:
          "Back it up before you have data. Lose it and every encrypted secret in the instance is gone, and no database restore brings them back.",
        docs: "/docs/guides/operate/back-up-and-restore",
        docs_label: "Back up and restore"
      },
      %{
        title: "Upgrades are yours to run",
        body:
          "Pull the tag, run the migrations, read the note. There is no window where somebody else does it for you, and no window where somebody else does it to you.",
        docs: "/docs/guides/operate/upgrade",
        docs_label: "Upgrade an instance"
      }
    ]
  end

  @doc "The questions somebody asks between reading this page and running the clone."
  def self_host_faq do
    [
      %{
        q: "Is it really the same code?",
        a:
          "The same image and the same manifests. Every merge publishes deploy/ as an OCI artifact, and the hosted instance deploys from that artifact. There is no private overlay, and no patch that only we have."
      },
      %{
        q: "Does the AGPL reach my application?",
        a:
          "No. Your application talks to your instance over HTTP, and the CLI and the SDK are Apache-2.0 for exactly that reason. The copyleft has one target: somebody who changes the server and then offers the changed server to other people as a service."
      },
      %{
        q: "What do I pay for the software?",
        a:
          "Nothing. There is no licence key and no seat count, and nobody has to talk to us first. Leave credits off and the instance prices nothing and shows nobody a bill. Turn credits on and it bills your users rather than you."
      },
      %{
        q: "Do I still bring a model key?",
        a:
          "Yes, and you always did. The agent bills your Anthropic, OpenAI or Google account for tokens. Nothing in the middle takes a cut of inference, hosted or not."
      },
      %{
        q: "Can I try the hosted one first?",
        a:
          "Yes, and none of it is wasted. The console, the CLI and the API are the same on both, and so are the SDK and the manual. What changes is whose machine it runs on."
      },
      %{
        q: "How much of an instance is one person?",
        a:
          "A container, a Postgres and a sandbox token. It ships with a compose file that brings the database with it, and plain Kubernetes manifests for when it outgrows that."
      }
    ]
  end

  ## /case-studies/self-healing-infrastructure

  # The case study is data first, like /integrations above. Every number here
  # was counted once, by hand, over the window `case_window/0` names: the
  # dispatch counts and turn durations from this deployment's own database,
  # the pull requests and their timestamps from the estate's repository. They
  # are literals on purpose. A figure that recomputed at request time would
  # quietly widen its own window and end up claiming something nobody checked.

  @doc "The window every number on the case study covers."
  def case_window, do: "11 to 25 August 2026"

  @doc "The four headline numbers, counted over `case_window/0`."
  def case_stats do
    [
      %{
        value: "78",
        label: "incidents handled by an agent",
        note: "Fifteen days, one estate, one agent, no rota."
      },
      %{
        value: "4m 27s",
        label: "from alert to open pull request",
        note: "Measured on the incident below. The second one took 4m 08s."
      },
      %{
        value: "7.5 min",
        label: "median incident, start to verdict",
        note: "Half finish faster. The longest ran 50 minutes."
      },
      %{
        value: "0",
        label: "cluster credentials the agent holds",
        note: "No kubectl, no kubeconfig, no write anywhere."
      }
    ]
  end

  @doc "The loop, in the order it runs."
  def case_loop do
    [
      %{
        step: "1",
        title: "Prometheus notices",
        mono: "KubePodCrashLooping · PodOOMKilled · CPUThrottlingHigh · PodRestartChurn",
        body:
          "The same alert rules the estate already had. Nothing was written to make " <>
            "an agent happy, and nothing about the agent is wired into Prometheus."
      },
      %{
        step: "2",
        title: "Alertmanager forks the page",
        mono: "continue: true",
        body:
          "One copy goes to the operator's phone, exactly as before. A sibling copy " <>
            "goes to a webhook. The human is added to, never replaced."
      },
      %{
        step: "3",
        title: "A webhook hires an agent",
        mono: "POST /api/conversations",
        body:
          "Two hundred lines of Node with an API key, an agent id, a vault id and the " <>
            "alert text. It has no cluster access of its own, and needs none. Hiring the " <>
            "agent is one call."
      },
      %{
        step: "4",
        title: "The agent reads the estate",
        mono: "Authorization: Bearer … (GET only)",
        body:
          "A read-only service answers with each node's health verdict, its drift " <>
            "against source, and the controller's own conditions. Every other method " <>
            "returns 405, so the token cannot be turned into a write."
      },
      %{
        step: "5",
        title: "It finds the wrong fact in git",
        mono: "gh api · git log -S",
        body:
          "The cluster is a repository, so a bad cluster is a bad commit. The agent " <>
            "reads the source and its history and names the change that introduced the " <>
            "fault, before it edits anything."
      },
      %{
        step: "6",
        title: "It opens one minimal pull request",
        mono: "symptom · root cause · why this diff is the whole fix",
        body:
          "Source and regenerated manifests in one commit, under a separate GitHub " <>
            "identity with push rights and nothing more. If no change to the repository " <>
            "can fix the alert, it writes that instead and opens nothing."
      },
      %{
        step: "7",
        title: "A human approves",
        mono: "422 on self-approval · 405 on self-merge",
        body:
          "The one gate. The agent pushes as an identity that GitHub refuses to let " <>
            "approve its own work, and the branch requires a review from somebody else. " <>
            "The gate is not a policy the agent is asked to respect. It cannot reach it."
      },
      %{
        step: "8",
        title: "Flux applies the merge",
        mono: "reconcile on webhook",
        body:
          "Git was always the apply path, so there is no apply button for the agent to " <>
            "be trusted with. The merge is the deploy."
      },
      %{
        step: "9",
        title: "The agent verifies and reports",
        mono: "poll until healthy",
        body:
          "It watches the degraded node come back, checks that nothing else regressed, " <>
            "and posts the incident summary. Then it stops."
      }
    ]
  end

  @doc "What the agent may do, and the mechanism that stops the rest."
  def case_guardrails do
    [
      %{
        can: "Read the whole estate graph, including every controller's conditions.",
        cannot: "Change anything in the cluster. The token is refused on any method but GET."
      },
      %{
        can: "Clone the infrastructure repository and push a branch.",
        cannot: "Push to the default branch. It is protected, and a pull request is required."
      },
      %{
        can: "Open a pull request and answer review comments on it.",
        cannot:
          "Approve or merge that pull request. GitHub blocks self-approval, " <>
            "and the branch needs one review from another account."
      },
      %{
        can: "Reference a secret by name, so the fix restores the reference.",
        cannot:
          "Read a secret value. The material never leaves the cluster, " <>
            "and no diff it writes contains one."
      },
      %{
        can: "Say that no change to the repository can fix this, and stop.",
        cannot: "Reach the cluster directly. The sandbox has no kubectl and no kubeconfig."
      }
    ]
  end

  @doc """
  One real incident, in the order it happened. All times UTC, 25 August 2026.
  """
  def case_timeline do
    [
      %{
        time: "06:58:15",
        title: "A sidecar is killed for memory",
        body:
          "Alertmanager posts PodOOMKilled on a container that keeps a checkout in " <>
            "sync. The operator's phone buzzes. So does a webhook, which opens a " <>
            "conversation with the agent."
      },
      %{
        time: "06:59:34",
        title: "A second alert, same container",
        body:
          "CPUThrottlingHigh, at 94.44%. It opens its own incident, and a second agent " <>
            "starts work on it."
      },
      %{
        time: "07:02:42",
        title: "The first pull request opens",
        body:
          "Two files, nine lines added and four removed. The agent had traced the kill " <>
            "to a code path the container's limit was never sized for, and to the commit " <>
            "that first made the estate take it."
      },
      %{
        time: "07:03:42",
        title: "The second pull request opens",
        body:
          "Six lines added, two removed. The throttling had the same cause seen from " <>
            "the other side, and the agent said so rather than repeating the diagnosis."
      },
      %{
        time: "08:50:27",
        title: "A human wakes up and reads two pull requests",
        body:
          "The throttling fix is approved and merged. Flux reconciles on the merge " <>
            "webhook, and the agent watches the container come back."
      },
      %{
        time: "23:46:01",
        title: "The memory fix follows",
        body:
          "Nothing was on fire, so it waited for a proper read. That is what the gate " <>
            "is for."
      }
    ]
  end

  @doc """
  The agent's own words, quoted from the pull request it opened at 07:02.

  Segmented rather than one string, because the source is a Markdown pull
  request body and rendering its backticks as literal characters in a
  blockquote reads as a mistake. `{:code, _}` becomes a code span, so the
  quote stays word for word.
  """
  def case_quote do
    [
      {:text, "Both modes call "},
      {:code, "install_members()"},
      {:text, " ("},
      {:code, "make install"},
      {:text, " → "},
      {:code, "npm ci"},
      {:text, " across every member) whenever a fetched commit touches a "},
      {:code, "package-lock.json"},
      {:text, ". The "},
      {:code, "repo-sync"},
      {:text,
       " sidecar's limit was sized only for its cheap steady-state git-fetch loop and " <>
         "never accounted for this shared, memory-heavy reinstall path — a gap latent " <>
         "since the container was authored and invisible until a commit actually moved " <>
         "a lockfile."}
    ]
  end

  @doc "What each Fountain primitive did in this loop."
  def case_primitives do
    [
      %{
        title: "Agent",
        body:
          "The runtime, the model, the runbook and the tools, written once as a file in " <>
            "a public repository and applied to Fountain. The runbook is the whole " <>
            "product: diagnose, fix by pull request, wait for the human, verify, report."
      },
      %{
        title: "Environment",
        body:
          "The machine the agent wakes up on, with the repository, the CLI it needs, and " <>
            "the address of the read-only estate service. Described once, rebuilt per " <>
            "incident, never patched by hand."
      },
      %{
        title: "Vault",
        body:
          "The bot identity, kept apart from the environment on purpose. Swap the vault " <>
            "and the same agent acts as a different GitHub account. The token arrives as " <>
            "an environment variable and stays out of the prompt, the model's context and " <>
            "the stored transcript."
      },
      %{
        title: "Conversation",
        body:
          "One incident, one sandbox, one transcript, addressable by the alert it came " <>
            "from. It survives a diagnosis that runs for an hour, and it is a link a " <>
            "human can open at 08:50 to see everything the agent did at 07:02."
      }
    ]
  end

  @doc "The dispatcher, reduced to the part that matters. Kept out of the template."
  def case_dispatch_example do
    """
    // Alertmanager POSTs here.
    // This is the entire integration.
    await fetch(`${FOUNTAIN_URL}/api/conversations`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${FOUNTAIN_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        agent_id: agentId,  // estate-medic
        vault_id: vaultId,  // the identity it acts as
        prompt: [
          `The estate is alerting.`,
          alertLines,
          `Diagnose it. If a change to the repo can`,
          `fix it, open one minimal PR, wait for the`,
          `human merge, verify healthy, and report.`,
          `If nothing in the repo can fix it, do not`,
          `open a PR. Say so and stop.`,
        ].join("\\n\\n"),
      }),
    });\
    """
  end
end
