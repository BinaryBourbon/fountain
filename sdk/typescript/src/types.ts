/**
 * The wire shapes this SDK depends on. They are a subset: Fountain's REST API
 * returns more fields than these, and the objects are passed through, so
 * anything not named here is still on the value at runtime.
 */

/** The agent runtimes Fountain can start. */
export type Runtime = "claude" | "codex" | "gemini" | "opencode";

/** Sandbox backends. `null` on an agent means "the instance default". */
export type SandboxProvider = "sprites" | "e2b" | "daytona" | "runner";

/**
 * A skill given to an agent — either written into the sandbox verbatim, or
 * installed from GitHub. Exactly one of `content` or `source` per entry.
 */
export type SkillInput =
  | { name: string; content: string; source?: never; ref?: never }
  | { source: string; ref?: string; name?: string; content?: never };

/** A repository the environment clones into the sandbox before the agent starts. */
export interface Repository {
  url: string;
  mount_path: string;
}

/**
 * An agent definition: everything that decides how a run behaves, before the
 * prompt. This is the same vocabulary as the REST API and a `fountain.yml`
 * manifest — deliberately, so one definition reads the same in all three.
 */
export interface AgentInput {
  name: string;
  /** Canonical `provider/model_id`, e.g. `anthropic/claude-sonnet-5`. */
  model: string;
  runtime: Runtime;
  description?: string;
  /** The agent's system prompt. */
  system?: string;
  /** Sandbox backend override; `null` inherits the instance default. */
  sandbox_provider?: SandboxProvider | null;
  /** The environment this agent runs in by default. */
  environment_id?: string | null;
  skills?: SkillInput[];
  /** MCP servers, in the runtime's own config shape. */
  mcp_servers?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  /**
   * Vaults a conversation may attach. `null` (default) allows any the account
   * owns, `[]` forbids all of them, a list is an allowlist. Vault values
   * override the environment on a key collision, so this is what scopes who
   * can override reviewed config.
   */
  allowed_vault_ids?: string[] | null;
  /** Environments a conversation may launch under instead of this agent's own. */
  allowed_environment_ids?: string[] | null;
}

/** A named, re-runnable agent config, as the API returns it. */
export interface Agent extends Partial<AgentInput> {
  id: string;
  name: string;
  /** Whether the runtime speaks the Agent Client Protocol. Derived, never stored. */
  acp?: boolean;
  conversation_count?: number;
  avatar_media_type?: string | null;
  inserted_at?: string;
  updated_at?: string;
  [key: string]: unknown;
}

/** Egress policy. `limited` with no `allowed_hosts` denies everything. */
export type NetworkingType = "unrestricted" | "limited";

/** The sandbox an agent runs in, before any conversation exists. */
export interface EnvironmentInput {
  name: string;
  /** Packages to install, keyed by manager (`apt`, `npm`, ...). */
  packages?: Record<string, unknown>;
  /** Non-secret environment variables. Secrets go through `secrets.set`. */
  env_vars?: Record<string, string>;
  setup_script?: string;
  networking_type?: NetworkingType;
  networking_config?: { allowed_hosts?: string[] } & Record<string, unknown>;
  repositories?: Repository[];
  metadata?: Record<string, unknown>;
}

/** An environment, as the API returns it. */
export interface Environment extends Partial<EnvironmentInput> {
  id: string;
  name: string;
  secret_count?: number;
  /** Agents referencing this environment — 0 means it is safe to delete. */
  agent_count?: number;
  inserted_at?: string;
  updated_at?: string;
  [key: string]: unknown;
}

/** A free-floating bag of env-var overrides, picked per conversation. */
export interface VaultInput {
  name: string;
  description?: string;
  metadata?: Record<string, unknown>;
}

/** A vault, as the API returns it. */
export interface Vault extends Partial<VaultInput> {
  id: string;
  name: string;
  secret_count?: number;
  inserted_at?: string;
  updated_at?: string;
  [key: string]: unknown;
}

/** A stored secret. Values are write-only — the API never returns them. */
export interface Secret {
  id: string;
  key: string;
  environment_id?: string;
  vault_id?: string;
  inserted_at?: string;
  updated_at?: string;
  [key: string]: unknown;
}

/** A named thing an agent can be given: an environment or a vault. */
export interface NamedResource {
  id: string;
  name: string;
  [key: string]: unknown;
}

export type ConversationStatus =
  | "provisioning"
  | "running"
  | "idle"
  | "suspended"
  | "failed"
  | "terminated"
  | (string & {});

/** One run of an agent inside a sandbox. */
export interface Conversation {
  id: string;
  status: ConversationStatus;
  agent_id?: string;
  title?: string | null;
  runtime?: string;
  turn_count?: number;
  last_active_at?: string | null;
  [key: string]: unknown;
}

/** One prompt and everything the agent did in response. */
export interface Turn {
  turn_number: number;
  status?: string;
  prompt?: string;
  exit_code?: number | null;
  started_at?: string | null;
  ended_at?: string | null;
  [key: string]: unknown;
}

/**
 * A server-parsed piece of an agent's output. `?blocks=true` is what makes the
 * log feed portable: no client re-parses a runtime's dialect.
 */
export interface Block {
  kind: "text" | "thinking" | "tool_use" | "result" | "error" | "raw" | "init" | (string & {});
  body?: string;
  name?: string;
  [key: string]: unknown;
}

/** One row of the conversation's log feed. */
export interface LogEvent {
  id: number;
  kind: "output" | "stage" | (string & {});
  /** `stdout`, `stderr`, `acp` or `stage`. */
  stream?: string;
  /** Raw output for an `output` event; JSON-encoded metadata for a `stage` one. */
  data?: string;
  /** `provision`, `setup`, `turn`, `reattach`, `sandbox`, `terminate`. */
  stage?: string;
  state?: string;
  turn_id?: string | null;
  ts?: string;
  blocks?: Block[];
  [key: string]: unknown;
}

/** How a turn ended. `timeout` means the SDK stopped waiting, not that the agent stopped. */
export type TurnState = "done" | "failed" | "interrupted" | "timeout";

/** What the agent streams back while it works. */
export type RunEvent =
  | { type: "conversation"; conversationId: string; conversation: Conversation; url: string }
  | { type: "turn-start"; turnNumber: number; turnId: string | null }
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "tool"; name: string; block: Block }
  | { type: "block"; block: Block; event: LogEvent }
  | { type: "event"; event: LogEvent }
  | { type: "turn-end"; state: TurnState; exitCode: number | null; reason: string | null };

/** The finished turn. */
export interface RunResult {
  /** The conversation the turn ran in. Keep it: the sandbox is still there. */
  conversationId: string;
  /** Where a human watches it. */
  url: string;
  /** Which turn this was — 1 for a fresh `run`, 2+ for a `send`. */
  turnNumber: number;
  /** Everything the agent said, tool noise removed. */
  text: string;
  /** Tool names the agent used, in the order it first used each. */
  toolsUsed: string[];
  /** How the turn ended. */
  state: TurnState;
  /** The runtime's exit code when it reported one. */
  exitCode: number | null;
  /** Why it stopped, when the runtime said (`stop_reason`, a failure message). */
  reason: string | null;
  /** The conversation's status when the turn ended. */
  status: ConversationStatus | null;
  /** Every log event consumed, when `collectEvents` was set. */
  events?: LogEvent[];
}
