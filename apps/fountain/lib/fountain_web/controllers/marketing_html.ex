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
            "your own an OAuth flow whose tokens are ordinary API keys.",
        docs: "/docs/api",
        docs_label: "The API reference",
        works_with: [
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
end
