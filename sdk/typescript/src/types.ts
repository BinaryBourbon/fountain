/**
 * The SDK's own vocabulary.
 *
 * Anything the API defines comes from `schemas.ts`, which is generated from
 * the OpenAPI document — so it cannot drift. What is left here is what a spec
 * cannot say: that many log events fold into one *turn*, that a run can be
 * awaited or streamed, and how a turn ended.
 */
export type {
  Agent,
  AgentInput,
  AgentPatch,
  AuthMe,
  Block,
  Catalog,
  ConversationRecord,
  ConversationTreeNode,
  Environment,
  EnvironmentInput,
  EnvironmentPatch,
  ImageInput,
  LogEvent,
  Repository,
  Runner,
  Schedule,
  ScheduleInput,
  SchedulePatch,
  SearchHit,
  Secret,
  TeamAddInput,
  TeamCommsStatus,
  Teammate,
  TeammateContact,
  Turn,
  Vault,
  VaultInput,
  VaultPatch,
  VaultSecret,
} from "./schemas.ts";

import type { Agent, Block, ConversationRecord, LogEvent } from "./schemas.ts";

/** The agent runtimes Fountain can start. */
export type Runtime = NonNullable<Agent["runtime"]>;

/** Sandbox backends. `null` on an agent means "the instance default". */
export type SandboxProvider = NonNullable<Agent["sandbox_provider"]>;

/** A conversation's lifecycle status. */
export type ConversationStatus = ConversationRecord["status"];

/**
 * A skill given to an agent — either written into the sandbox verbatim, or
 * installed from GitHub. Exactly one of `content` or `source` per entry; the
 * spec cannot express that, so this narrows what the generated type allows.
 */
export type SkillInput =
  | { name: string; content: string; source?: never; ref?: never }
  | { source: string; ref?: string; name?: string; content?: never };

/** The log-event streams a conversation carries. */
export type Stream = "stdout" | "stderr" | "acp" | "stage";

/** How a turn ended. `timeout` means the SDK stopped waiting, not that the agent did. */
export type TurnState = "done" | "failed" | "interrupted" | "timeout";

/** What a run emits while it works. */
export type RunEvent =
  | { type: "conversation"; conversationId: string; conversation: ConversationRecord; url: string }
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
  /** Why it stopped, when the runtime said. */
  reason: string | null;
  /** The conversation's status when the turn ended. */
  status: string | null;
  /** Every log event consumed, when `collectEvents` was set. */
  events?: LogEvent[];
}

/** A named thing an agent can be given: an environment or a vault. */
export interface NamedResource {
  id: string;
  name: string;
  [key: string]: unknown;
}
