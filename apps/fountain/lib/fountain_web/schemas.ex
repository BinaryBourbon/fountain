defmodule FountainWeb.Schemas do
  @moduledoc """
  OpenAPI schemas shared across controllers. One module per resource so
  controller `operation` decls can reference them by atom (e.g.
  `Schemas.Agent`).
  """

  alias OpenApiSpex.Schema

  defmodule Sandbox do
    @moduledoc false

    use FountainWeb.DerivedSchema,
      source: Fountain.Conversations.Sandbox,
      title: "Sandbox",
      description: "One sprite lifespan owned by a conversation.",
      expose: [:id, :sprite_name, {:status, enum: :statuses}],
      required: [:id, :sprite_name, :status]
  end

  defmodule Conversation do
    @moduledoc false
    use FountainWeb.DerivedSchema,
      source: Fountain.Conversations.Conversation,
      title: "Conversation",
      description: "One chat with one agent inside one sandbox.",
      expose: [
        :id,
        {:title, nullable: true, doc: "Generated from the first turn; null until one exists."},
        {:sandbox_id, nullable: true},
        {:sandbox, schema: %Schema{oneOf: [Sandbox], nullable: true}},
        {:agent_id, nullable: true},
        {:vault_id, nullable: true},
        # The runtime vocabulary belongs to Agent — a conversation copies it
        # at spawn and the column carries no inclusion validation of its own.
        {:runtime, enum: {Fountain.Agents.Agent, :runtimes}},
        {:status, enum: :statuses},
        {:runtime_session_id, nullable: true},
        {:source, enum: :sources},
        {:parent_conversation_id, nullable: true},
        :turn_count,
        {:last_active_at,
         nullable: true,
         doc:
           "Most recent runtime output, falling back to creation time. Stage " <>
             "events (reconnects, sandbox lifecycle) do not count."},
        {:last_read_at,
         nullable: true, doc: "Set by `POST /api/conversations/:id/read`. Null if never read."},
        :inserted_at,
        :updated_at
      ],
      extra: %{
        unread: %Schema{
          type: :boolean,
          description: "last_active_at is later than last_read_at (true if never read)."
        }
      },
      required: [:id, :runtime, :status]
  end

  defmodule ConversationTreeNode do
    @moduledoc false

    use FountainWeb.DerivedSchema,
      source: Fountain.Conversations.Conversation,
      title: "ConversationTreeNode",
      description: "One conversation in a spawn tree, flat with a parent pointer.",
      expose: [:id, {:source, enum: :sources}, {:status, enum: :statuses}],
      # `parent_id` on the wire, `parent_conversation_id` in the column.
      extra: %{parent_id: %Schema{type: :string, format: :uuid, nullable: true}},
      required: [:id]
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
          enum: Fountain.Images.valid_media_types(),
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Conversations.Turn,
      title: "Turn",
      description: "One prompt → exit_code cycle within a conversation.",
      expose: [
        :id,
        :turn_number,
        :prompt,
        {:status, enum: :statuses},
        {:exit_code, nullable: true},
        {:started_at, nullable: true},
        {:ended_at, nullable: true},
        :inserted_at
      ],
      extra: %{
        image_count: %Schema{
          type: :integer,
          description: "Number of images attached to this turn."
        }
      },
      required: [:id, :turn_number, :prompt, :status]
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
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.runtimes()},
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
          enum: Fountain.Images.valid_media_types(),
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
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.runtimes()},
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
        runtime: %Schema{type: :string, enum: Fountain.Agents.Agent.runtimes()},
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Environments.Environment,
      title: "Environment",
      description: "A reusable sandbox environment: packages, env vars, repos, networking.",
      expose: [
        :id,
        :name,
        :packages,
        {:env_vars, additional_properties: %Schema{type: :string}},
        :setup_script,
        {:networking_type, enum: :networking},
        {:networking_config,
         doc:
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
         }},
        {:repositories, items: Repository},
        :metadata,
        {:secret_count, doc: "Secrets stored on this environment."},
        {:agent_count, doc: "Agents referencing this environment — 0 means safe to delete."},
        :inserted_at,
        :updated_at
      ],
      required: [:id, :name]
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
        networking_type: %Schema{
          type: :string,
          enum: Fountain.Environments.Environment.networking()
        },
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
        networking_type: %Schema{
          type: :string,
          enum: Fountain.Environments.Environment.networking()
        },
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Environments.Secret,
      title: "Secret",
      description: "A named secret. Values are write-only — the API never returns them.",
      expose: [:id, :key, :environment_id, :inserted_at, :updated_at],
      required: [:id, :key, :environment_id]
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Vaults.Vault,
      title: "Vault",
      description:
        "A free-floating bag of env-var overrides selected at conversation creation. " <>
          "Vault values override an environment's baseline secrets when the same key is set on both.",
      expose: [
        :id,
        :name,
        :description,
        :metadata,
        {:secret_count, doc: "Secrets stored in this vault."},
        :inserted_at,
        :updated_at
      ],
      required: [:id, :name]
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Vaults.VaultSecret,
      title: "VaultSecret",
      description:
        "A named secret in a vault. Values are write-only — the API never returns them.",
      expose: [:id, :key, :vault_id, :inserted_at, :updated_at],
      required: [:id, :key, :vault_id]
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Conversations.LogEvent,
      title: "LogEvent",
      description:
        "One line of a conversation's log feed: runtime output or a lifecycle " <>
          "stage transition. Same fields the SSE stream sends, plus `id`.",
      expose: [
        {:id, doc: "Monotonic id. Pagination cursor here, `Last-Event-ID` on the SSE route."},
        {:kind, enum: :kinds},
        # No enum, deliberately: stage events carry "" here, so the honest
        # list would be ["stdout", "stderr", ""]. See LogEvent.streams/0.
        {:stream, doc: "`stdout` / `stderr` for output events; empty for stage events."},
        {:data, doc: "Output text, or JSON-encoded metadata for stage events."},
        {:stage, doc: "Lifecycle stage name (stage events)."},
        {:state, enum: :states, nullable: true},
        {:duration_ms, nullable: true},
        {:turn_id, nullable: true}
      ],
      # `ts` on the wire, `inserted_at` in the column.
      extra: %{ts: %Schema{type: :string, format: :"date-time"}},
      required: [:id, :kind, :ts]
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Accounts.User,
      title: "AdminUser",
      description: "An account as the operator surface sees it. Metadata only.",
      expose: [
        :id,
        :email,
        {:role, enum: :roles},
        {:email_verified_at, nullable: true},
        {:suspended_at, nullable: true},
        # No enum, unlike BillingResponse.data.status: this surface also
        # renders accounts that predate the billing columns.
        {:subscription_status, nullable: true},
        {:trial_ends_at, nullable: true},
        {:current_period_end, nullable: true},
        {:cancel_at_period_end, nullable: true},
        {:max_concurrent_sandboxes, nullable: true},
        {:onboarding_completed_at, nullable: true},
        :inserted_at
      ],
      # Computed by the admin JSON view rather than stored.
      extra: %{
        email_verified: %Schema{type: :boolean},
        suspended: %Schema{type: :boolean},
        has_stripe_customer: %Schema{type: :boolean},
        active_sandboxes: %Schema{type: :integer},
        last_activity_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :email, :role]
  end

  defmodule AdminUserResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminUserResponse",
      type: :object,
      properties: %{data: AdminUser},
      required: [:data]
    })
  end

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
      properties: %{role: %Schema{type: :string, enum: Fountain.Accounts.User.roles()}},
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Conversations.Sandbox,
      title: "AdminSandbox",
      description: "A live sandbox, cross-tenant. Metadata only — never contents.",
      expose: [
        :id,
        :sprite_name,
        # Intentionally unconstrained here, unlike Schemas.Sandbox: this list
        # is cross-tenant and includes rows written before the status set settled.
        :status,
        {:user_id, nullable: true},
        :inserted_at,
        :updated_at
      ],
      extra: %{
        user_email: %Schema{type: :string, nullable: true},
        conversation_count: %Schema{type: :integer}
      },
      required: [:id, :status]
  end

  defmodule AdminSandboxListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminSandboxListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: AdminSandbox}},
      required: [:data]
    })
  end

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

  defmodule AdminAuditListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AdminAuditListResponse",
      description: "Cross-tenant audit events; each carries the tenant it belongs to.",
      type: :object,
      # Fully qualified: AuditEvent is defined further down this file, and the
      # implicit alias a nested defmodule creates only exists after it.
      properties: %{data: %Schema{type: :array, items: FountainWeb.Schemas.AuditEvent}},
      required: [:data]
    })
  end

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
              enum: Fountain.Accounts.User.subscription_statuses(),
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Exports.Export,
      title: "Export",
      description:
        "An account data export. Built asynchronously; the payload is fetched " <>
          "from the download endpoint, never embedded here.",
      expose: [
        :id,
        {:status, enum: :statuses},
        {:byte_size, nullable: true, doc: "Uncompressed size."},
        {:error, nullable: true},
        {:expires_at, nullable: true},
        :inserted_at,
        :updated_at
      ],
      extra: %{
        downloadable: %Schema{
          type: :boolean,
          description: "Completed and not yet expired — the only state the download serves."
        }
      },
      required: [:id, :status]
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
          enum: Fountain.Images.valid_media_types()
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
              enum: Fountain.Accounts.onboarding_states(),
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Audit.Event,
      title: "AuditEvent",
      description: "One entry in the account's append-only audit trail.",
      expose: [
        {:id, doc: "Cursor for `before`."},
        :inserted_at,
        {:actor,
         nullable: true,
         doc:
           "Which surface acted: `ui` (browser session), `api` (bearer key), " <>
             "`sprite` (a per-conversation token held by a sandbox), `system`."},
        {:action, example: "vault.secret.write"},
        {:resource_type, nullable: true},
        {:resource_id, nullable: true},
        :metadata,
        {:request_ip, nullable: true}
      ],
      required: [:id, :action, :inserted_at]
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

    # Not derived: `Credential` is one row per tenant with a ciphertext column
    # per provider, so there is no `provider` field to derive from. This schema
    # is a projection over providers/0 — which is still where the vocabulary
    # lives, so the list is read rather than restated.
    OpenApiSpex.schema(%{
      title: "InferenceCredentialStatus",
      description:
        "Whether a provider credential is set for the tenant. Values are " <>
          "write-only — the API never returns a credential, truncated or otherwise.",
      type: :object,
      properties: %{
        provider: %Schema{
          type: :string,
          enum: Enum.map(Fountain.InferenceCredentials.Credential.providers(), &Atom.to_string/1)
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
        kind: %Schema{type: :string, enum: Fountain.Manifest.kinds()},
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
        role: %Schema{type: :string, enum: Fountain.Accounts.User.roles()},
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
    use FountainWeb.DerivedSchema,
      source: Fountain.Accounts.ApiKey,
      title: "ApiKey",
      description: "Key metadata. Never the key itself, and never its hash.",
      expose: [
        :id,
        :name,
        {:last_used_at, nullable: true},
        {:scopes,
         doc:
           "`full` for a key a person minted; `sprite:<conversation_id>` for the " <>
             "auto-issued token a sandbox holds."},
        {:expires_at, nullable: true}
      ],
      # Renames: `prefix` from key_prefix, `created_at` from inserted_at.
      # key_hash is absent by construction — only listed fields are emitted.
      extra: %{
        prefix: %Schema{type: :string},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :prefix, :created_at]
  end

  defmodule ApiKeyListResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ApiKeyListResponse",
      type: :object,
      # ApiKey is referenced by the implicit alias the nested defmodule above
      # created; it only exists after that definition, hence the ordering.
      properties: %{data: %Schema{type: :array, items: ApiKey}},
      required: [:data]
    })
  end

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
