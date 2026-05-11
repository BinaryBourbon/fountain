defmodule FountainWeb.Schemas do
  @moduledoc """
  OpenAPI schemas shared across controllers. One module per resource so
  controller `operation` decls can reference them by atom (e.g.
  `Schemas.Agent`).
  """

  alias OpenApiSpex.Schema

  defmodule Sandbox do
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
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Conversation",
      description: "One chat with one agent inside one sandbox.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        sandbox_id: %Schema{type: :string, format: :uuid, nullable: true},
        sandbox: %Schema{oneOf: [Sandbox], nullable: true},
        agent_id: %Schema{type: :string, format: :uuid, nullable: true},
        vault_id: %Schema{type: :string, format: :uuid, nullable: true},
        runtime: %Schema{type: :string, enum: ~w(claude codex gemini opencode)},
        status: %Schema{
          type: :string,
          enum: ~w(pending running idle completed failed terminated)
        },
        runtime_session_id: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :runtime, :status]
    })
  end

  defmodule ConversationResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ConversationResponse",
      type: :object,
      properties: %{data: Conversation},
      required: [:data]
    })
  end

  defmodule ConversationListResponse do
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
            "Optional vault whose secrets override the environment's baseline at sprite spawn."
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
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PromptResponse",
      type: :object,
      properties: %{status: %Schema{type: :string, example: "queued"}},
      required: [:status]
    })
  end

  defmodule Turn do
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
        image_count: %Schema{type: :integer, description: "Number of images attached to this turn."}
      },
      required: [:id, :turn_number, :prompt, :status]
    })
  end

  defmodule TurnListResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TurnListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Turn}},
      required: [:data]
    })
  end

  defmodule Agent do
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
              "or github (`{source, name?}` — installed on the sprite via the skills.sh CLI). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{type: :string, description: "Skill name (required for inline entries)."},
              content: %Schema{type: :string, description: "Full SKILL.md body for inline entries."},
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name, :model, :runtime]
    })
  end

  defmodule AgentResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentResponse",
      type: :object,
      properties: %{data: Agent},
      required: [:data]
    })
  end

  defmodule AgentListResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AgentListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Agent}},
      required: [:data]
    })
  end

  defmodule AgentRequest do
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
              "or github (`{source, name?}` — installed on the sprite via the skills.sh CLI). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{type: :string, description: "Skill name (required for inline entries)."},
              content: %Schema{type: :string, description: "Full SKILL.md body for inline entries."},
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true}
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
              "or github (`{source, name?}` — installed on the sprite via the skills.sh CLI). " <>
              "Exactly one of `content` or `source` must be set on each entry.",
          items: %Schema{
            type: :object,
            properties: %{
              name: %Schema{type: :string, description: "Skill name (required for inline entries)."},
              content: %Schema{type: :string, description: "Full SKILL.md body for inline entries."},
              source: %Schema{
                type: :string,
                description: "GitHub `owner/repo` for skills.sh-sourced entries.",
                pattern: "^[A-Za-z0-9._/-]+$"
              }
            }
          }
        },
        mcp_servers: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule Repository do
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
        networking_config: %Schema{type: :object, additionalProperties: true},
        repositories: %Schema{type: :array, items: Repository},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  defmodule EnvironmentResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentResponse",
      type: :object,
      properties: %{data: Environment},
      required: [:data]
    })
  end

  defmodule EnvironmentListResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EnvironmentListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Environment}},
      required: [:data]
    })
  end

  defmodule EnvironmentRequest do
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
        networking_config: %Schema{type: :object, additionalProperties: true},
        repositories: %Schema{type: :array, items: Repository}
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
        networking_config: %Schema{type: :object, additionalProperties: true},
        repositories: %Schema{type: :array, items: Repository}
      }
    })
  end

  defmodule Secret do
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
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretResponse",
      type: :object,
      properties: %{data: Secret},
      required: [:data]
    })
  end

  defmodule SecretListResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SecretListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Secret}},
      required: [:data]
    })
  end

  defmodule SecretRequest do
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
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :name]
    })
  end

  defmodule VaultResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultResponse",
      type: :object,
      properties: %{data: Vault},
      required: [:data]
    })
  end

  defmodule VaultListResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: Vault}},
      required: [:data]
    })
  end

  defmodule VaultRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, minLength: 1, maxLength: 200},
        description: %Schema{type: :string}
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
        description: %Schema{type: :string}
      }
    })
  end

  defmodule VaultSecret do
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
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretResponse",
      type: :object,
      properties: %{data: VaultSecret},
      required: [:data]
    })
  end

  defmodule VaultSecretListResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VaultSecretListResponse",
      type: :object,
      properties: %{data: %Schema{type: :array, items: VaultSecret}},
      required: [:data]
    })
  end

  defmodule VaultSecretRequest do
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
