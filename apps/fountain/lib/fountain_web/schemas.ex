defmodule FountainWeb.Schemas do
  @moduledoc """
  OpenAPI schemas shared across controllers. One module per resource so
  controller `operation` decls can reference them by atom (e.g.
  `Schemas.Agent`).
  """

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
          enum: ~w(pending starting ready terminated failed)
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
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
        status: %Schema{
          type: :string,
          enum: ~w(pending running idle failed terminated)
        },
        runtime_session_id: %Schema{type: :string, nullable: true},
        source: %Schema{type: :string, enum: ~w(ui api agent)},
        parent_conversation_id: %Schema{type: :string, format: :uuid, nullable: true},
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

  defmodule ConversationTreeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationTreeResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: ConversationTreeNode}},
      required: [:data]
    })
  end

  defmodule ConversationResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationResponse",
      type: :object,
      properties: %{data: Conversation},
      required: [:data]
    })
  end

  defmodule ConversationListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Conversation}
      },
      required: [:data]
    })
  end

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

  defmodule TurnListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TurnListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Turn}},
      required: [:data]
    })
  end

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
          description: "Canonical provider/model_id (e.g. anthropic/claude-sonnet-4-6).",
          pattern: "^[a-z0-9_-]+/[a-z0-9._-]+$"
        },
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
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

  defmodule AgentResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentResponse",
      type: :object,
      properties: %{data: Agent},
      required: [:data]
    })
  end

  defmodule AgentListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Agent}},
      required: [:data]
    })
  end

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

  defmodule EnvironmentResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentResponse",
      type: :object,
      properties: %{data: Environment},
      required: [:data]
    })
  end

  defmodule EnvironmentListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Environment}},
      required: [:data]
    })
  end

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

  defmodule SecretResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretResponse",
      type: :object,
      properties: %{data: Secret},
      required: [:data]
    })
  end

  defmodule SecretListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Secret}},
      required: [:data]
    })
  end

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

  defmodule VaultResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultResponse",
      type: :object,
      properties: %{data: Vault},
      required: [:data]
    })
  end

  defmodule VaultListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Vault}},
      required: [:data]
    })
  end

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

  defmodule VaultSecretResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretResponse",
      type: :object,
      properties: %{data: VaultSecret},
      required: [:data]
    })
  end

  defmodule VaultSecretListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: VaultSecret}},
      required: [:data]
    })
  end

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

  defmodule ExportResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportResponse",
      type: :object,
      properties: %{data: Export},
      required: [:data]
    })
  end

  defmodule ExportListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExportListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Export}},
      required: [:data]
    })
  end

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

  defmodule InferenceCredentialResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialResponse",
      type: :object,
      properties: %{data: InferenceCredentialStatus},
      required: [:data]
    })
  end

  defmodule InferenceCredentialListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InferenceCredentialListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: InferenceCredentialStatus}},
      required: [:data]
    })
  end

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
end
