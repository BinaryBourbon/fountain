defmodule FountainBuzz.Schemas do
  @moduledoc """
  The extension's OpenAPI schemas (ADR 0043, #1507).

  Moved out of `FountainWeb.Schemas` unchanged. The **module** names moved;
  every `title:` is byte-identical to what it was in core, because a title is
  the component key in the published document and the four SDKs are generated
  from it (#1411). Renaming one here would be an SDK break, which ADR 0043
  decision 6 promises not to make.

  `FountainWeb.SchemaWrappers` is imported rather than reimplemented: the
  `%{data: ...}` envelope is the host's shape and stays the host's.
  """

  import FountainWeb.SchemaWrappers, only: [list_response: 2, item_response: 2]

  alias OpenApiSpex.Schema

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
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          nullable: true,
          description:
            "Where this identity's conversations run (ADR 0023): a sandbox per " <>
              "conversation, or the agent's one persistent machine. null means the " <>
              "agent's own default."
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
        sandbox_mode: %Schema{
          type: :string,
          enum: ~w(ephemeral persistent),
          nullable: true,
          description:
            "Where this identity's conversations run (ADR 0023), passed to the harness " <>
              "as fountain acp --sandbox-mode. Omitted means the agent's own default; " <>
              "omitted on a re-provision clears a previously set one. A re-provision that " <>
              "changes it restarts a running harness."
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

  defmodule BuzzAccessUpdateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BuzzAccessUpdateRequest",
      description:
        "Change who may @-mention a hosted Buzz agent. Sets buzz-acp's inbound author " <>
          "gate on the identity and restarts its harness. At least one field is required. " <>
          "A later provider deploy from the desktop resends the desktop's record and " <>
          "overwrites this.",
      type: :object,
      properties: %{
        respond_to: %Schema{
          type: :string,
          enum: ~w(owner-only allowlist anyone nobody),
          nullable: true
        },
        respond_to_allowlist: %Schema{
          type: :array,
          items: %Schema{type: :string},
          nullable: true,
          description: "64-hex pubkeys; required non-empty when respond_to is allowlist."
        }
      }
    })
  end

  item_response(BuzzIdentityResponse, of: BuzzIdentity)

  list_response(BuzzIdentityListResponse, of: BuzzIdentity)
end
