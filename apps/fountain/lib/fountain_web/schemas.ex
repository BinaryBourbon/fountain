defmodule FountainWeb.Schemas do
  @moduledoc """
  OpenAPI schemas shared across controllers. One module per resource so
  controller `operation` decls can reference them by atom (e.g.
  `Schemas.Agent`).
  """

  import FountainWeb.SchemaWrappers, only: [list_response: 2, item_response: 2]

  alias OpenApiSpex.Schema

  defmodule Sandbox do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Sandbox",
      description: "One sprite lifespan owned by a conversation.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sprite_name: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ~w(pending starting ready suspended terminated failed)
        },
        url: %Schema{
          type: :string,
          nullable: true,
          description:
            "The sandbox's own HTTP endpoint, where a service the agent starts " <>
              "is reachable. Null for providers that expose no such URL. The " <>
              "same value is available inside the sandbox as `SANDBOX_URL`."
        }
      },
      required: [:id, :sprite_name, :status]
    })
  end

  defmodule Conversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Conversation",
      description: "One chat with one agent inside one sandbox.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        title: %Schema{
          type: :string,
          nullable: true,
          description: "Generated from the first turn; null until one exists."
        },
        sandbox_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox: %Schema{oneOf: [Sandbox], nullable: true},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Per-launch environment override; null means the agent's environment."
        },
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
        acp: %Schema{
          type: :boolean,
          readOnly: true,
          description:
            "Whether this conversation's runtime speaks the Agent Client Protocol. " <>
              "When true its output is stored as ACP `session/update` notifications on " <>
              "the `acp` event stream, which is what a protocol client replays; when " <>
              "false the output is the runtime's own dialect on `stdout`."
        },
        status: %Schema{
          type: :string,
          enum: ~w(pending running idle failed terminated)
        },
        runtime_session_id: %Schema{type: :string, nullable: true},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        parent_conversation_id: %Schema{type: :string, format: :uuid, nullable: true},
        channel_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "The external channel key this conversation is bound to, if it was created with one."
        },
        turn_count: %Schema{type: :integer},
        last_active_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "Most recent runtime output, falling back to creation time. Stage " <>
              "events (reconnects, sandbox lifecycle) do not count."
        },
        last_read_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Set by `POST /api/conversations/:id/read`. Null if never read."
        },
        unread: %Schema{
          type: :boolean,
          description: "last_active_at is later than last_read_at (true if never read)."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :runtime, :status]
    })
  end

  defmodule ConversationTreeNode do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationTreeNode",
      description: "One conversation in a spawn tree, flat with a parent pointer.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        status: %Schema{type: :string, enum: ~w(pending running idle failed terminated)},
        parent_id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:id]
    })
  end

  list_response(ConversationTreeResponse, of: ConversationTreeNode)

  item_response(ConversationResponse, of: Conversation)

  list_response(ConversationListResponse, of: Conversation)

  defmodule ImageInput do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ImageInput",
      description: "A base64-encoded image to attach to a prompt.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :string,
          description: "Base64-encoded image bytes."
        },
        media_type: %Schema{
          type: :string,
          enum: ~w(image/png image/jpeg image/gif image/webp),
          description: "MIME type of the image."
        }
      },
      required: [:data, :media_type]
    })
  end

  defmodule ConversationCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationCreateRequest",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string, format: :uuid},
        vault_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional vault whose secrets override the environment's baseline at sprite spawn. " <>
              "Must satisfy the agent's allowed_vault_ids when that allowlist is set."
        },
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional environment to provision from instead of the agent's own; the " <>
              "conversation stays pinned to it across wakes. Must be owned by the caller " <>
              "(404 otherwise) and satisfy the agent's allowed_environment_ids when that " <>
              "allowlist is set (422 environment_not_allowed). Part of the channel_id " <>
              "resume key."
        },
        prompt: %Schema{type: :string, description: "Optional first turn prompt."},
        images: %Schema{
          type: :array,
          items: ImageInput,
          description: "Optional images to attach to the initial prompt.",
          nullable: true
        },
        sprite_name: %Schema{
          type: :string,
          description: "Override the auto-generated sprite name."
        },
        channel_id: %Schema{
          type: :string,
          maxLength: 255,
          nullable: true,
          description:
            "Opaque key for the external channel this conversation is bound to (for example a " <>
              "Buzz channel id). When set, the latest live conversation for the same agent, vault " <>
              "and channel is resumed (200) instead of a new one being opened (201)."
        },
        fresh: %Schema{
          type: :boolean,
          nullable: true,
          description:
            "With channel_id: skip the resume and open a new conversation (201), which then " <>
              "becomes the channel's binding. Sent by a chat harness relaying its owner's " <>
              "rotate command. Ignored without channel_id."
        }
      },
      required: [:agent_id]
    })
  end

  defmodule PromptRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptRequest",
      type: :object,
      properties: %{
        prompt: %Schema{type: :string},
        images: %Schema{
          type: :array,
          items: ImageInput,
          description: "Optional images to attach to this prompt.",
          nullable: true
        }
      },
      required: [:prompt]
    })
  end

  defmodule PromptResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptResponse",
      type: :object,
      properties: %{status: %Schema{type: :string, example: "queued"}},
      required: [:status]
    })
  end

  defmodule Turn do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Turn",
      description: "One prompt → exit_code cycle within a conversation.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        turn_number: %Schema{type: :integer},
        prompt: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ~w(pending running completed failed interrupted)
        },
        exit_code: %Schema{type: :integer, nullable: true},
        started_at: %Schema{type: :string, format: :"date-time", nullable: true},
        ended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        image_count: %Schema{
          type: :integer,
          description: "Number of images attached to this turn."
        }
      },
      required: [:id, :turn_number, :prompt, :status]
    })
  end

  list_response(TurnListResponse, of: Turn)

  defmodule Agent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Agent",
      description: "An AI agent definition: runtime, model, skills, MCP, env.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        system: %Schema{type: :string, description: "System prompt."},
        model: %Schema{
          type: :string,
          description:
            "Canonical provider/model_id (e.g. anthropic/claude-sonnet-4-6). The " <>
              "provider must match the runtime — anthropic for claude, openai for " <>
              "codex, google for gemini; opencode accepts any of the three. Other " <>
              "providers are rejected: Fountain has no credentials to export for " <>
              "them. The model id is not checked against a list, so a newly " <>
              "released model works without a Fountain release.",
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
        acp: %Schema{
          type: :boolean,
          readOnly: true,
          description:
            "Whether this agent's runtime speaks the Agent Client Protocol. Derived " <>
              "from the runtime, never stored. When false, the conversation's output " <>
              "is the runtime's own dialect on the `stdout` stream rather than ACP " <>
              "`session/update` notifications on the `acp` stream, and a protocol " <>
              "client such as `fountain acp` cannot render it."
        },
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — installed on the sprite via the skills.sh CLI, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(installed as `owner/repo@ref`). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist. Vault values override the agent's " <>
              "environment on key collision, so this scopes who can override reviewed config."
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        conversation_count: %Schema{
          type: :integer,
          description: "Conversations started from this agent."
        },
        avatar_media_type: %Schema{
          type: :string,
          nullable: true,
          enum: ~w(image/png image/jpeg image/gif image/webp),
          description:
            "Set when the agent has an avatar; fetch the bytes at " <>
              "`GET /api/agents/:id/avatar`. Null means no avatar."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :model, :runtime]
    })
  end

  item_response(AgentResponse, of: Agent)

  list_response(AgentListResponse, of: Agent)

  defmodule BuzzIdentity do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BuzzIdentity",
      description:
        "A hosted Buzz agent: a Nostr identity (key held server-side in a vault) " <>
          "bound to a Fountain agent. Its harness runs on the gateway (ADR 0020).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        display_name: %Schema{type: :string, nullable: true},
        relay_url: %Schema{type: :string, description: "wss:// relay URL"},
        pubkey: %Schema{type: :string, description: "Nostr public key (hex)", nullable: true},
        agent_id: %Schema{type: :string, format: :uuid},
        vault_id: %Schema{type: :string, format: :uuid},
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Environment this identity's conversations are provisioned from instead of " <>
              "the agent's own; null means the agent's."
        },
        respond_to: %Schema{
          type: :string,
          enum: ~w(owner-only allowlist anyone nobody),
          description: "The harness's inbound author gate (buzz-acp --respond-to)."
        },
        respond_to_allowlist: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "64-hex pubkeys admitted in allowlist mode."
        },
        enabled: %Schema{type: :boolean},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :agent_id, :vault_id, :enabled]
    })
  end

  defmodule BuzzProvisionRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BuzzProvisionRequest",
      description:
        "Provision (or converge on) a hosted Buzz agent. The Nostr secret key is " <>
          "accepted here and stored server-side in the identity's vault; it is never " <>
          "returned and never enters a sandbox. Idempotent on `pubkey`.",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        relay_url: %Schema{type: :string, description: "wss:// relay URL"},
        agent_id: %Schema{type: :string, format: :uuid, description: "The Fountain agent to run"},
        pubkey: %Schema{
          type: :string,
          description: "Nostr public key (hex) — the convergence key"
        },
        private_key_nsec: %Schema{
          type: :string,
          description: "Nostr secret key (nsec/hex). Stored, never returned"
        },
        auth_tag: %Schema{type: :string, description: "NIP-OA owner attestation tag (JSON array)"},
        display_name: %Schema{type: :string, nullable: true},
        environment_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Optional environment to provision this identity's conversations from instead " <>
              "of the agent's own — one agent config, one environment per identity. Must be " <>
              "owned by the caller (404 otherwise) and, when the agent sets " <>
              "allowed_environment_ids, on that list (checked at conversation start). " <>
              "Omitted on a re-provision clears a previously set one."
        },
        respond_to: %Schema{
          type: :string,
          enum: ~w(owner-only allowlist anyone nobody),
          nullable: true,
          description:
            "Who may @-mention the agent and fire a turn — buzz-acp's --respond-to mode, " <>
              "set as BUZZ_ACP_RESPOND_TO on the hosted harness. Omitted means owner-only. " <>
              "A re-provision that changes it restarts a running harness."
        },
        respond_to_allowlist: %Schema{
          type: :array,
          items: %Schema{type: :string},
          nullable: true,
          description:
            "64-hex pubkeys admitted in allowlist mode (BUZZ_ACP_RESPOND_TO_ALLOWLIST). " <>
              "Required non-empty when respond_to is allowlist; ignored otherwise."
        }
      },
      required: [:name, :relay_url, :agent_id, :pubkey, :private_key_nsec, :auth_tag]
    })
  end

  item_response(BuzzIdentityResponse, of: BuzzIdentity)

  list_response(BuzzIdentityListResponse, of: BuzzIdentity)

  defmodule AgentRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        system: %Schema{type: :string},
        model: %Schema{
          type: :string,
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — installed on the sprite via the skills.sh CLI, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(installed as `owner/repo@ref`). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist."
        }
      },
      required: [:name, :model, :runtime]
    })
  end

  defmodule AgentUpdate do
    require OpenApiSpex

    @moduledoc """
    Partial update — every field is optional. Used by `PUT /api/agents/:id`.
    """

    OpenApiSpex.schema(%{
      title: "AgentUpdate",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        system: %Schema{type: :string},
        model: %Schema{type: :string, pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"},
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
        sandbox_provider: %Schema{
          type: :string,
          enum: ~w(sprites e2b daytona),
          nullable: true,
          description:
            "Sandbox backend override; null inherits the instance default " <>
              "(SANDBOX_PROVIDER). Only providers configured on this instance are accepted"
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        environment_id: %Schema{type: :string, format: :uuid, nullable: true},
        skills: %Schema{
          type: :array,
          description:
            "Each entry is either inline (`{name, content}` — full SKILL.md text written to the sprite) " <>
              "or github (`{source, ref?, name?}` — installed on the sprite via the skills.sh CLI, " <>
              "optionally pinned to a tag/branch/sha via `ref`). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{
                type: :string,
                description: "Skill name (required for inline entries)."
              },
              content: %Schema{
                type: :string,
                description: "Full SKILL.md body for inline entries."
              },
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              },
              ref: %Schema{
                type: :string,
                description:
                  "Optional tag, branch, or sha pinning a github-sourced skill " <>
                    "(installed as `owner/repo@ref`). Without it the default branch " <>
                    "is fetched at spawn time.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        allowed_vault_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Vaults a conversation may attach to this agent. null (default) allows " <>
              "any vault the tenant owns; an empty list forbids attaching any vault; " <>
              "a non-empty list is an allowlist."
        }
      }
    })
  end

  defmodule Repository do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Repository",
      type: :object,
      properties: %{
        url: %Schema{type: :string, format: :uri, pattern: "^https://"},
        mount_path: %Schema{type: :string, pattern: "^/"}
      },
      required: [:url, :mount_path]
    })
  end

  defmodule Environment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Environment",
      description: "A reusable sandbox environment: packages, env vars, repos, networking.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description:
            "Refines networking_type: limited. allowed_hosts is the only key " <>
              "honored today; unknown keys are ignored. Under limited, egress is " <>
              "restricted to the allowlisted domains. With no allowed_hosts (or an " <>
              "empty list), the sandbox denies all egress by default — this is a " <>
              "deny-all, not an allow-all.",
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        allowed_environment_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          nullable: true,
          description:
            "Environments a conversation may launch this agent under instead of its own " <>
              "(environment_id on create). Same shape as allowed_vault_ids: null (default) " <>
              "allows any environment the tenant owns; an empty list forbids overriding; " <>
              "a non-empty list is an allowlist. The agent's own environment always passes."
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true},
        secret_count: %Schema{type: :integer, description: "Secrets stored on this environment."},
        agent_count: %Schema{
          type: :integer,
          description: "Agents referencing this environment — 0 means safe to delete."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  item_response(EnvironmentResponse, of: Environment)

  list_response(EnvironmentListResponse, of: Environment)

  defmodule EnvironmentRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description:
            "Refines networking_type: limited. allowed_hosts is the only key " <>
              "honored today; unknown keys are ignored. Under limited, egress is " <>
              "restricted to the allowlisted domains. With no allowed_hosts (or an " <>
              "empty list), the sandbox denies all egress by default — this is a " <>
              "deny-all, not an allow-all.",
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name]
    })
  end

  defmodule EnvironmentUpdate do
    require OpenApiSpex

    @moduledoc """
    Partial update — every field is optional. The server merges into the
    existing record. Used by `PUT /api/environments/:id`.
    """

    OpenApiSpex.schema(%{
      title: "EnvironmentUpdate",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        packages: %Schema{type: :object, additionalProperties: true},
        env_vars: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        setup_script: %Schema{type: :string},
        networking_type: %Schema{type: :string, enum: ~w(unrestricted limited)},
        networking_config: %Schema{
          type: :object,
          description:
            "Refines networking_type: limited. allowed_hosts is the only key " <>
              "honored today; unknown keys are ignored. Under limited, egress is " <>
              "restricted to the allowlisted domains. With no allowed_hosts (or an " <>
              "empty list), the sandbox denies all egress by default — this is a " <>
              "deny-all, not an allow-all.",
          properties: %{
            allowed_hosts: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Domains the sandbox may reach when networking_type is limited."
            }
          },
          additionalProperties: true
        },
        repositories: %Schema{type: :array, items: Repository},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule Secret do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Secret",
      description: "A named secret. Values are write-only — the API never returns them.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string},
        environment_id: %Schema{type: :string, format: :uuid},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :environment_id]
    })
  end

  item_response(SecretResponse, of: Secret)

  list_response(SecretListResponse, of: Secret)

  defmodule SecretRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :string, description: "Secret value (write-only)."}
      },
      required: [:key, :value]
    })
  end

  defmodule Vault do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Vault",
      description:
        "A free-floating bag of env-var overrides selected at conversation creation. " <>
          "Vault values override an environment's baseline secrets when the same key is set on both.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true},
        secret_count: %Schema{type: :integer, description: "Secrets stored in this vault."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  item_response(VaultResponse, of: Vault)

  list_response(VaultListResponse, of: Vault)

  defmodule VaultRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [:name]
    })
  end

  defmodule VaultUpdate do
    require OpenApiSpex

    @moduledoc """
    Partial update — every field is optional. Used by `PUT /api/vaults/:id`.
    """

    OpenApiSpex.schema(%{
      title: "VaultUpdate",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule VaultSecret do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecret",
      description:
        "A named secret in a vault. Values are write-only — the API never returns them.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        key: %Schema{type: :string},
        vault_id: %Schema{type: :string, format: :uuid},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :key, :vault_id]
    })
  end

  item_response(VaultSecretResponse, of: VaultSecret)

  list_response(VaultSecretListResponse, of: VaultSecret)

  defmodule VaultSecretRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretRequest",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :string, description: "Secret value (write-only)."}
      },
      required: [:key, :value]
    })
  end

  defmodule LogEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LogEvent",
      description:
        "One line of a conversation's log feed: runtime output or a lifecycle " <>
          "stage transition. Same fields the SSE stream sends, plus `id`.",
      type: :object,
      properties: %{
        id: %Schema{
          type: :integer,
          description: "Monotonic id. Pagination cursor here, `Last-Event-ID` on the SSE route."
        },
        kind: %Schema{type: :string, enum: ~w(output stage)},
        stream: %Schema{
          type: :string,
          description: "`stdout` / `stderr` for output events; empty for stage events."
        },
        data: %Schema{
          type: :string,
          description: "Output text, or JSON-encoded metadata for stage events."
        },
        stage: %Schema{type: :string, description: "Lifecycle stage name (stage events)."},
        state: %Schema{type: :string, enum: ~w(started done failed interrupted), nullable: true},
        duration_ms: %Schema{type: :integer, nullable: true},
        turn_id: %Schema{type: :string, format: :uuid, nullable: true},
        ts: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :kind, :ts]
    })
  end

  defmodule LogEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LogEventListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: LogEvent},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            has_more: %Schema{type: :boolean},
            next_cursor: %Schema{
              type: :integer,
              nullable: true,
              description: "Pass as `after` to fetch the next page. null when the page is empty."
            }
          },
          required: [:limit, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AdminUser do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUser",
      description: "An account as the operator surface sees it. Metadata only.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string},
        role: %Schema{type: :string, enum: ~w(admin user)},
        email_verified: %Schema{type: :boolean},
        email_verified_at: %Schema{type: :string, format: :"date-time", nullable: true},
        suspended: %Schema{type: :boolean},
        suspended_at: %Schema{type: :string, format: :"date-time", nullable: true},
        subscription_status: %Schema{type: :string, nullable: true},
        trial_ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
        current_period_end: %Schema{type: :string, format: :"date-time", nullable: true},
        cancel_at_period_end: %Schema{type: :boolean, nullable: true},
        has_stripe_customer: %Schema{type: :boolean},
        max_concurrent_sandboxes: %Schema{type: :integer, nullable: true},
        active_sandboxes: %Schema{type: :integer},
        onboarding_completed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_activity_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :email, :role]
    })
  end

  item_response(AdminUserResponse, of: AdminUser)

  defmodule AdminUserListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUserListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: AdminUser},
        meta: %Schema{
          type: :object,
          properties: %{
            page: %Schema{type: :integer},
            per_page: %Schema{type: :integer},
            total: %Schema{type: :integer}
          },
          required: [:page, :per_page, :total]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule AdminRoleRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminRoleRequest",
      type: :object,
      properties: %{role: %Schema{type: :string, enum: ~w(admin user)}},
      required: [:role]
    })
  end

  defmodule AdminSandboxLimitRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSandboxLimitRequest",
      type: :object,
      properties: %{
        limit: %Schema{type: :integer, minimum: 0, description: "Concurrent sandbox cap."}
      },
      required: [:limit]
    })
  end

  defmodule AdminExtendTrialRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminExtendTrialRequest",
      type: :object,
      properties: %{days: %Schema{type: :integer, minimum: 1}},
      required: [:days]
    })
  end

  defmodule AdminCompRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminCompRequest",
      type: :object,
      properties: %{comped: %Schema{type: :boolean}},
      required: [:comped]
    })
  end

  defmodule AdminSuspendRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSuspendRequest",
      type: :object,
      properties: %{suspended: %Schema{type: :boolean}},
      required: [:suspended]
    })
  end

  defmodule AdminResyncResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminResyncResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            outcome: %Schema{type: :string, enum: ~w(resynced customer_sync_enqueued)},
            subscription_status: %Schema{type: :string, nullable: true}
          },
          required: [:outcome]
        }
      },
      required: [:data]
    })
  end

  defmodule AdminSandbox do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSandbox",
      description: "A live sandbox, cross-tenant. Metadata only — never contents.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sprite_name: %Schema{type: :string},
        provider: %Schema{type: :string, description: "Sandbox backend that owns this row"},
        status: %Schema{type: :string},
        user_id: %Schema{type: :string, format: :uuid, nullable: true},
        user_email: %Schema{type: :string, nullable: true},
        conversation_count: %Schema{type: :integer},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status]
    })
  end

  list_response(AdminSandboxListResponse, of: AdminSandbox)

  defmodule AdminReapResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminReapResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            sandbox_id: %Schema{type: :string, format: :uuid},
            outcome: %Schema{type: :string, enum: ~w(terminated released already_terminal)}
          },
          required: [:outcome]
        }
      },
      required: [:data]
    })
  end

  # Fully qualified: AuditEvent is defined further down this file, and the
  # implicit alias a nested defmodule creates only exists after it.
  list_response(AdminAuditListResponse,
    of: FountainWeb.Schemas.AuditEvent,
    description: "Cross-tenant audit events; each carries the tenant it belongs to."
  )

  defmodule AdminEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminEventListResponse",
      description: "The privilege trail: who did what to whom.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :integer},
              inserted_at: %Schema{type: :string, format: :"date-time"},
              event_type: %Schema{type: :string, example: "admin.account.suspended"},
              actor_user_id: %Schema{type: :string, format: :uuid, nullable: true},
              target_user_id: %Schema{type: :string, format: :uuid, nullable: true},
              metadata: %Schema{type: :object, additionalProperties: true}
            },
            required: [:event_type]
          }
        }
      },
      required: [:data]
    })
  end

  defmodule BillingResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BillingResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            status: %Schema{
              type: :string,
              enum: ~w(trialing active past_due canceled comped),
              nullable: true
            },
            trial_ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
            current_period_end: %Schema{type: :string, format: :"date-time", nullable: true},
            cancel_at_period_end: %Schema{
              type: :boolean,
              description: "Access continues until current_period_end."
            },
            has_stripe_customer: %Schema{type: :boolean},
            period: %Schema{
              type: :object,
              description: "The window the usage numbers cover (current calendar month).",
              properties: %{
                start: %Schema{type: :string, format: :"date-time"},
                end: %Schema{type: :string, format: :"date-time"}
              }
            },
            usage: %Schema{
              type: :object,
              properties: %{
                conversations: %Schema{type: :integer},
                turns: %Schema{type: :integer},
                sandbox_minutes: %Schema{type: :number}
              }
            }
          },
          required: [:status, :usage]
        }
      },
      required: [:data]
    })
  end

  defmodule StripeUrlResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StripeUrlResponse",
      description: "A Stripe-hosted URL to open in a browser. Single-use and short-lived.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{url: %Schema{type: :string, format: :uri}},
          required: [:url]
        }
      },
      required: [:data]
    })
  end

  defmodule Export do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Export",
      description:
        "An account data export. Built asynchronously; the payload is fetched " <>
          "from the download endpoint, never embedded here.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ~w(pending completed failed)},
        byte_size: %Schema{type: :integer, nullable: true, description: "Uncompressed size."},
        error: %Schema{type: :string, nullable: true},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        downloadable: %Schema{
          type: :boolean,
          description: "Completed and not yet expired — the only state the download serves."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :status]
    })
  end

  item_response(ExportResponse, of: Export)

  list_response(ExportListResponse, of: Export)

  defmodule AccountDeleteRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AccountDeleteRequest",
      type: :object,
      properties: %{
        confirm: %Schema{
          type: :string,
          description: "The account's own email address, exactly."
        }
      },
      required: [:confirm]
    })
  end

  defmodule AccountDeletedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AccountDeletedResponse",
      type: :object,
      properties: %{
        deleted: %Schema{type: :boolean},
        user_id: %Schema{type: :string, format: :uuid},
        sprites_destroyed: %Schema{type: :integer}
      },
      required: [:deleted]
    })
  end

  defmodule AvatarRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AvatarRequest",
      description:
        "JSON form of an avatar upload. The raw-bytes form sends the image " <>
          "directly with an image content-type instead.",
      type: :object,
      properties: %{
        data: %Schema{type: :string, description: "Base64-encoded image bytes."},
        media_type: %Schema{
          type: :string,
          enum: ~w(image/png image/jpeg image/gif image/webp)
        }
      },
      required: [:data, :media_type]
    })
  end

  defmodule OnboardingResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "OnboardingResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            state: %Schema{
              type: :string,
              nullable: true,
              enum: ~w(step_1 step_2 step_3 step_4 completed),
              description: "Wizard position. Only `completed` means anything to an API client."
            },
            completed: %Schema{type: :boolean},
            completed_at: %Schema{type: :string, format: :"date-time", nullable: true}
          },
          required: [:completed]
        }
      },
      required: [:data]
    })
  end

  defmodule AuditEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEvent",
      description: "One entry in the account's append-only audit trail.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Cursor for `before`."},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        actor: %Schema{
          type: :string,
          nullable: true,
          description:
            "Which surface acted: `ui` (browser session), `api` (bearer key), " <>
              "`sprite` (a per-conversation token held by a sandbox), `system`."
        },
        action: %Schema{type: :string, example: "vault.secret.write"},
        resource_type: %Schema{type: :string, nullable: true},
        resource_id: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        request_ip: %Schema{type: :string, nullable: true}
      },
      required: [:id, :action, :inserted_at]
    })
  end

  defmodule AuditEventListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEventListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: AuditEvent},
        meta: %Schema{
          type: :object,
          properties: %{
            limit: %Schema{type: :integer},
            has_more: %Schema{type: :boolean},
            next_cursor: %Schema{
              type: :integer,
              nullable: true,
              description: "Pass as `before` for the next (older) page."
            }
          },
          required: [:limit, :has_more]
        }
      },
      required: [:data, :meta]
    })
  end

  defmodule InferenceCredentialStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialStatus",
      description:
        "Whether a provider credential is set for the tenant. Values are " <>
          "write-only — the API never returns a credential, truncated or otherwise.",
      type: :object,
      properties: %{
        provider: %Schema{
          type: :string,
          enum: ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)
        },
        set: %Schema{type: :boolean}
      },
      required: [:provider, :set]
    })
  end

  item_response(InferenceCredentialResponse, of: InferenceCredentialStatus)

  list_response(InferenceCredentialListResponse, of: InferenceCredentialStatus)

  defmodule InferenceCredentialRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialRequest",
      type: :object,
      properties: %{
        value: %Schema{
          type: :string,
          description: "The provider token (write-only)."
        },
        validate: %Schema{
          type: :boolean,
          default: true,
          description:
            "Ping the provider to check the credential before storing it. " <>
              "false stores it unchecked."
        }
      },
      required: [:value]
    })
  end

  defmodule HealthResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthResponse",
      type: :object,
      properties: %{status: %Schema{type: :string, example: "ok"}},
      required: [:status]
    })
  end

  defmodule ReadinessResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReadinessResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["ok", "error"], example: "ok"},
        checks: %Schema{
          type: :object,
          description: "Per-dependency result. `ok` or `error`, with no further detail.",
          additionalProperties: %Schema{type: :string, enum: ["ok", "error"]},
          example: %{"database" => "ok"}
        }
      },
      required: [:status, :checks]
    })
  end

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      properties: %{error: %Schema{type: :string}},
      required: [:error]
    })
  end

  defmodule ManifestResource do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ManifestResource",
      description:
        "One compiled document from a fountain.yml manifest. `spec` matches the " <>
          "create/update schema for the kind, plus an inline `secrets` map " <>
          "(Environment and Vault). Agent specs may reference an environment by " <>
          "name via `environment`; the server resolves it to `environment_id`.",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: ["Environment", "Vault", "Agent"]},
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        spec: %Schema{type: :object, additionalProperties: true}
      },
      required: [:kind, :name]
    })
  end

  defmodule ApplyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyRequest",
      type: :object,
      properties: %{
        resources: %Schema{type: :array, items: ManifestResource}
      },
      required: [:resources]
    })
  end

  defmodule ApplySecretResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplySecretResult",
      description: "Outcome for one secret key. Values are never echoed back.",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        action: %Schema{type: :string, enum: ["upserted", "error"]},
        errors: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      required: [:key, :action]
    })
  end

  defmodule ApplyResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyResult",
      type: :object,
      properties: %{
        kind: %Schema{type: :string},
        name: %Schema{type: :string},
        action: %Schema{type: :string, enum: ["created", "updated", "error"]},
        errors: %Schema{type: :object, additionalProperties: true, nullable: true},
        secrets: %Schema{type: :array, items: ApplySecretResult}
      },
      required: [:kind, :name, :action]
    })
  end

  defmodule ApplyResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApplyResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{results: %Schema{type: :array, items: ApplyResult}},
          required: [:results]
        }
      },
      required: [:data]
    })
  end

  defmodule ChangesetError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChangesetError",
      description: "Validation errors keyed by field, with each value an array of messages.",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        }
      },
      required: [:errors]
    })
  end

  ## ─── Auth (#571) ───────────────────────────────────────────────────────────
  #
  # The `/api/auth/*` surface. Errors here carry a machine-readable `error`
  # alongside the prose `message`, which the resource endpoints' plain
  # `Schemas.Error` does not — a client retrying a reset needs to tell
  # `expired` from `invalid_token` without parsing English.

  defmodule AuthError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthError",
      description: "An auth failure with a stable reason code.",
      type: :object,
      properties: %{
        error: %Schema{
          type: :string,
          description:
            "Reason code, e.g. `expired`, `invalid_token`, `invalid_current_password`.",
          example: "invalid_token"
        },
        message: %Schema{type: :string, description: "Human-readable detail."}
      },
      required: [:error]
    })
  end

  defmodule MessageResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MessageResponse",
      type: :object,
      properties: %{message: %Schema{type: :string}},
      required: [:message]
    })
  end

  defmodule AuthTokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthTokenRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password}
      },
      required: [:email, :password]
    })
  end

  defmodule AuthTokenResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthTokenResponse",
      description: "A freshly minted full-scope key. `api_key` is shown once and never again.",
      type: :object,
      properties: %{
        api_key: %Schema{type: :string, example: "ftn_live_..."},
        key_id: %Schema{type: :string, format: :uuid},
        prefix: %Schema{
          type: :string,
          description: "Leading characters of the key, the only part stored in the clear."
        }
      },
      required: [:api_key, :key_id, :prefix]
    })
  end

  defmodule AuthMeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthMeResponse",
      description: "Identity of the account the bearer token belongs to.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string, format: :email},
        role: %Schema{type: :string, enum: ~w(user admin)},
        email_verified: %Schema{type: :boolean},
        onboarding_state: %Schema{
          type: :string,
          nullable: true,
          description: "Wizard position. Only `completed` means anything to an API client."
        },
        onboarding_completed: %Schema{type: :boolean},
        subscription_status: %Schema{
          type: :string,
          nullable: true,
          description: "Always null when billing is disabled on the instance (#480)."
        }
      },
      required: [:id, :email, :role, :email_verified]
    })
  end

  defmodule ApiKey do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKey",
      description: "Key metadata. Never the key itself, and never its hash.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"},
        last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
        scopes: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description:
            "`full` for a key a person minted; `sprite:<conversation_id>` for the " <>
              "auto-issued token a sandbox holds."
        },
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :name, :prefix, :created_at]
    })
  end

  # ApiKey is referenced by the implicit alias the nested defmodule above
  # created; it only exists after that definition, hence the ordering.
  list_response(ApiKeyListResponse, of: ApiKey)

  defmodule ApiKeyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, description: "What this key is for."}
      },
      required: [:name]
    })
  end

  defmodule ApiKeyCreatedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyCreatedResponse",
      description: "The one and only response that carries key material.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        key: %Schema{type: :string, description: "Plaintext key. Not recoverable afterwards."},
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :key, :prefix]
    })
  end

  defmodule RegisterRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password}
      },
      required: [:email, :password]
    })
  end

  defmodule RegisterResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "RegisterResponse",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        message: %Schema{type: :string}
      },
      required: [:user_id, :message]
    })
  end

  defmodule EmailRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailRequest",
      type: :object,
      properties: %{email: %Schema{type: :string, format: :email}},
      required: [:email]
    })
  end

  defmodule TokenRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TokenRequest",
      description: "A token lifted out of an emailed link.",
      type: :object,
      properties: %{token: %Schema{type: :string}},
      required: [:token]
    })
  end

  defmodule VerifyEmailResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VerifyEmailResponse",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid},
        email_verified: %Schema{type: :boolean},
        message: %Schema{type: :string}
      },
      required: [:user_id, :email_verified, :message]
    })
  end

  defmodule PasswordResetRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordResetRequest",
      type: :object,
      properties: %{
        token: %Schema{type: :string, description: "From the reset email."},
        password: %Schema{type: :string, format: :password}
      },
      required: [:token, :password]
    })
  end

  defmodule PasswordChangeRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordChangeRequest",
      type: :object,
      properties: %{
        current_password: %Schema{type: :string, format: :password},
        new_password: %Schema{type: :string, format: :password}
      },
      required: [:current_password, :new_password]
    })
  end

  defmodule PasswordChangeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasswordChangeResponse",
      type: :object,
      properties: %{
        message: %Schema{type: :string},
        sessions_invalidated: %Schema{type: :boolean},
        api_keys_revoked: %Schema{
          type: :boolean,
          description:
            "Always false. API keys are separate credentials with their own " <>
              "expiries; revoke them yourself at `DELETE /api/auth/api-keys/{id}`."
        }
      },
      required: [:message, :sessions_invalidated, :api_keys_revoked]
    })
  end

  defmodule EmailChangeRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailChangeRequest",
      type: :object,
      properties: %{
        new_email: %Schema{type: :string, format: :email},
        current_password: %Schema{type: :string, format: :password}
      },
      required: [:new_email, :current_password]
    })
  end

  defmodule EmailChangedResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EmailChangedResponse",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email, description: "The new address."},
        message: %Schema{type: :string}
      },
      required: [:email, :message]
    })
  end
end
