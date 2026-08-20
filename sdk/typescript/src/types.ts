/**
 * The wire shapes this SDK depends on. They are a subset: Fountain's REST API
 * returns more fields than these, and the objects are passed through, so
 * anything not named here is still on the value at runtime.
 */

/** A named, re-runnable agent config — runtime, model, skills, environment. */
export interface Agent {
  id: string;
  name: string;
  runtime?: string;
  model?: string;
  description?: string | null;
  environment_id?: string | null;
  [key: string]: unknown;
}

/** A named bag of things an agent can be given: an environment or a vault. */
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
