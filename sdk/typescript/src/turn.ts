import type { Block, LogEvent, RunEvent, TurnState } from "./types.ts";

const TERMINAL_TURN_STATES = new Set(["done", "failed", "interrupted"]);

/**
 * Folds the log feed into one turn's answer.
 *
 * The feed carries every turn of the conversation and every stream of each
 * turn, so "what did the agent just say" is a filtering problem, not a
 * concatenation one. This class is the filter:
 *
 *   - a `stage`/`turn` event opens and closes the turn we are following, and
 *     is the only thing that says how it ended;
 *   - `output` events carry server-parsed `blocks`; only `text` is the answer,
 *     `tool_use` is noise worth naming, `thinking` is neither;
 *   - text that follows a tool call is a new message, so it gets a paragraph
 *     break — the rule that stops a transcript reading as one run-on sentence.
 *
 * The joining rules are ported from the Hermes plugin, which learned them
 * against real runtimes: ACP streams one message as chunks that join with
 * nothing, while a legacy stdout row is a whole message and joins as a
 * paragraph.
 */
export class TurnFollower {
  readonly turnNumber: number;
  turnId: string | null = null;
  started = false;
  state: TurnState | null = null;
  exitCode: number | null = null;
  reason: string | null = null;

  private readonly chunks: string[] = [];
  private readonly tools: string[] = [];
  private breakBeforeText = false;

  constructor(turnNumber: number, turnId: string | null = null) {
    this.turnNumber = turnNumber;
    this.turnId = turnId;
  }

  get text(): string {
    return this.chunks.join("").trim();
  }

  get toolsUsed(): string[] {
    return [...this.tools];
  }

  get finished(): boolean {
    return this.state !== null;
  }

  /** Fold one event in, and report what a streaming caller should be told. */
  apply(event: LogEvent): RunEvent[] {
    if (event.kind === "stage") return this.applyStage(event);
    if (event.kind !== "output") return [];
    return this.applyOutput(event);
  }

  private applyStage(event: LogEvent): RunEvent[] {
    if (event.stage !== "turn") return [];
    const meta = parseJson(event.data) ?? {};
    if (!this.matchesTurn(meta)) return [];

    if (event.state === "started") {
      this.started = true;
      this.turnId = asString(meta.turn_id) ?? this.turnId;
      return [{ type: "turn-start", turnNumber: this.turnNumber, turnId: this.turnId }];
    }

    if (event.state && TERMINAL_TURN_STATES.has(event.state)) {
      this.state = event.state as TurnState;
      this.turnId = this.turnId ?? asString(meta.turn_id);
      if (typeof meta.exit_code === "number") this.exitCode = meta.exit_code;
      const reason = asString(meta.reason) ?? asString(meta.stop_reason);
      if (reason) this.reason = reason;
      return [
        { type: "turn-end", state: this.state, exitCode: this.exitCode, reason: this.reason },
      ];
    }

    return [];
  }

  private matchesTurn(meta: Record<string, unknown>): boolean {
    if (this.turnId && asString(meta.turn_id) === this.turnId) return true;
    return meta.turn_number === this.turnNumber;
  }

  private applyOutput(event: LogEvent): RunEvent[] {
    const turnId = asString(event.turn_id);
    // A different turn's output — history, or a turn someone else started.
    if (this.turnId && turnId && turnId !== this.turnId) return [];
    // Output from before our turn opened is the tail of an older one.
    if (!this.started && !this.turnId) return [];

    const acp = event.stream === "acp";
    const out: RunEvent[] = [];

    for (const block of event.blocks ?? []) {
      out.push({ type: "block", block, event });
      out.push(...this.applyBlock(block, acp));
    }
    return out;
  }

  private applyBlock(block: Block, acp: boolean): RunEvent[] {
    const body = block.body ?? "";

    if (block.kind === "text") {
      if (!body) return [];
      const prefix = this.paragraphBreak(acp);
      if (prefix) this.chunks.push(prefix);
      this.chunks.push(body);
      this.breakBeforeText = false;
      return [{ type: "text", text: prefix + body }];
    }

    if (block.kind === "thinking") {
      return body ? [{ type: "thinking", text: body }] : [];
    }

    // `raw` and `init` are transport bookkeeping: not output, and not a break.
    if (block.kind === "raw" || block.kind === "init") return [];

    this.breakBeforeText = true;

    if (block.kind === "tool_use") {
      const name = asString(block.name);
      if (!name) return [];
      if (!this.tools.includes(name)) this.tools.push(name);
      return [{ type: "tool", name, block }];
    }

    // A `result` block is the answer only when the runtime said nothing else.
    if (block.kind === "result" && !this.chunks.length && body) {
      this.chunks.push(body);
      return [{ type: "text", text: body }];
    }

    if (block.kind === "error" && body) {
      const text = `\n[error] ${body}\n`;
      this.chunks.push(text);
      return [{ type: "text", text }];
    }

    return [];
  }

  /**
   * ACP chunks are pieces of one message and join with nothing; anything after
   * a tool call is a new message. A legacy row is a whole message either way.
   */
  private paragraphBreak(acp: boolean): string {
    if (!this.chunks.length) return "";
    if (acp && !this.breakBeforeText) return "";
    const last = this.chunks[this.chunks.length - 1] ?? "";
    return last.endsWith("\n") ? "" : "\n\n";
  }
}

function parseJson(raw: unknown): Record<string, unknown> | null {
  if (raw && typeof raw === "object") return raw as Record<string, unknown>;
  if (typeof raw !== "string" || !raw.trim()) return null;
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value ? value : null;
}
