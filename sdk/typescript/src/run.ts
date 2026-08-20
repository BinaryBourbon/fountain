import type { HttpClient } from "./http.ts";
import type { Conversation, LogEvent, RunEvent, RunResult } from "./types.ts";
import { TurnFollower } from "./turn.ts";
import { streamEvents } from "./sse.ts";
import { Broadcast, deferred } from "./queue.ts";
import { conversationUrl } from "./config.ts";
import { TimeoutError } from "./errors.ts";

const TERMINAL_CONVERSATION_STATUSES = new Set(["failed", "terminated"]);

export interface RunPlan {
  /** Open the conversation (a fresh `run`), or reuse one (`send`). */
  start(): Promise<{ conversation: Conversation; turnNumber: number; after: number }>;
}

export interface RunOptions {
  /** Stop waiting after this many ms and throw `TimeoutError`. `0` (default) waits. */
  timeoutMs?: number;
  /** Abort the run's own waiting. The turn keeps going in the sandbox. */
  signal?: AbortSignal;
  /** Keep every log event on the result. Off by default — a long turn is a lot of rows. */
  collectEvents?: boolean;
}

/**
 * A turn in flight.
 *
 * The work starts as soon as you call `run()`; what you do with this object
 * decides how much of it you see. `await` it for the answer, iterate it for
 * events as they land, or read `.textStream` for just the words. All three
 * read the same underlying run — there is no second request behind them.
 */
export class Run implements Promise<RunResult>, AsyncIterable<RunEvent> {
  readonly [Symbol.toStringTag]: string = "Run";

  /** The conversation this turn runs in. Resolves as soon as it exists. */
  readonly conversationId: Promise<string>;
  /** Where a human watches it. Resolves with `conversationId`. */
  readonly url: Promise<string>;
  /** The full conversation record, once opened. */
  readonly conversation: Promise<Conversation>;

  private readonly http: HttpClient;
  private readonly events = new Broadcast<RunEvent>();
  private readonly completion: Promise<RunResult>;
  private readonly opened = deferred<Conversation>();
  private readonly abort = new AbortController();
  private lastEventId = 0;
  private conversationIdValue: string | null = null;

  constructor(http: HttpClient, plan: RunPlan, options: RunOptions = {}) {
    this.http = http;
    this.conversation = this.opened.promise;
    this.conversationId = hushed(this.conversation.then((c) => c.id));
    this.url = hushed(this.conversation.then((c) => conversationUrl(c.id, http.config)));
    this.completion = this.execute(plan, options);
    // A caller may only ever iterate, or only ever read `conversationId`. None
    // of these derived promises may crash the process for want of a handler —
    // the failure still arrives on whichever one is actually awaited.
    hushed(this.completion);
  }

  then<A = RunResult, B = never>(
    onfulfilled?: ((value: RunResult) => A | PromiseLike<A>) | null,
    onrejected?: ((reason: unknown) => B | PromiseLike<B>) | null,
  ): Promise<A | B> {
    return this.completion.then(onfulfilled, onrejected);
  }

  catch<B = never>(onrejected?: ((reason: unknown) => B | PromiseLike<B>) | null): Promise<RunResult | B> {
    return this.completion.catch(onrejected);
  }

  finally(onfinally?: (() => void) | null): Promise<RunResult> {
    return this.completion.finally(onfinally);
  }

  [Symbol.asyncIterator](): AsyncIterator<RunEvent> {
    return this.events[Symbol.asyncIterator]();
  }

  /** Just the words, as they arrive. */
  get textStream(): AsyncIterable<string> {
    const events = this.events;
    return {
      async *[Symbol.asyncIterator]() {
        for await (const event of events) {
          if (event.type === "text") yield event.text;
        }
      },
    };
  }

  /** Stop waiting. The turn keeps running in the sandbox; `interrupt()` stops that. */
  cancel(): void {
    this.abort.abort();
  }

  /** Ask the agent to stop the turn it is on. The sandbox stays up. */
  async interrupt(): Promise<void> {
    const id = await this.conversationId;
    await this.http.request("POST", `/api/conversations/${id}/interrupt`);
  }

  /** Tear the sandbox down. Nothing resumes after this. */
  async terminate(): Promise<void> {
    const id = await this.conversationId;
    await this.http.request("POST", `/api/conversations/${id}/terminate`);
  }

  /** The cursor to resume the log feed from — how a follow-up turn skips history. */
  get cursor(): number {
    return this.lastEventId;
  }

  private async execute(plan: RunPlan, options: RunOptions): Promise<RunResult> {
    try {
      const { conversation, turnNumber, after } = await plan.start();
      this.conversationIdValue = conversation.id;
      this.lastEventId = after;
      this.opened.resolve(conversation);
      const url = conversationUrl(conversation.id, this.http.config);
      this.events.push({ type: "conversation", conversationId: conversation.id, conversation, url });

      const result = await this.follow(conversation, turnNumber, after, options, url);
      this.events.close();
      return result;
    } catch (error) {
      this.opened.reject(error);
      this.events.close(error);
      throw error;
    }
  }

  private async follow(
    conversation: Conversation,
    turnNumber: number,
    after: number,
    options: RunOptions,
    url: string,
  ): Promise<RunResult> {
    const follower = new TurnFollower(turnNumber);
    const collected: LogEvent[] = [];
    const signal = options.signal
      ? AbortSignal.any([options.signal, this.abort.signal])
      : this.abort.signal;

    let timedOut = false;
    const timeoutMs = options.timeoutMs ?? 0;
    const timer =
      timeoutMs > 0
        ? setTimeout(() => {
            timedOut = true;
            this.abort.abort();
          }, timeoutMs)
        : null;
    timer?.unref?.();

    try {
      for await (const event of streamEvents(this.http, conversation.id, { after, signal })) {
        if (typeof event.id === "number" && event.id > this.lastEventId) this.lastEventId = event.id;
        if (options.collectEvents) collected.push(event);
        this.events.push({ type: "event", event });

        for (const out of follower.apply(event)) this.events.push(out);
        if (follower.finished) break;

        // The sandbox died, or someone tore it down: no turn event is coming.
        if (isConversationOver(event)) break;
      }
    } finally {
      if (timer) clearTimeout(timer);
    }

    if (timedOut) {
      throw new TimeoutError(
        `Timed out after ${timeoutMs}ms waiting for turn ${turnNumber}. ` +
          `The turn is still running — resume conversation ${conversation.id}.`,
        conversation.id,
        follower.text,
      );
    }

    const status = await this.currentStatus(conversation);
    if (!follower.finished) {
      // Aborted, or the stream ended with the conversation. Report what there is.
      this.events.push({ type: "turn-end", state: "timeout", exitCode: null, reason: null });
    }

    const result: RunResult = {
      conversationId: conversation.id,
      url,
      turnNumber,
      text: follower.text,
      toolsUsed: follower.toolsUsed,
      state: follower.state ?? "timeout",
      exitCode: follower.exitCode,
      reason: follower.reason,
      status,
    };
    if (options.collectEvents) result.events = collected;
    return result;
  }

  /** The status as of the end of the wait, not as of the last event. */
  private async currentStatus(conversation: Conversation): Promise<Conversation["status"] | null> {
    try {
      const fresh = await this.http.data<Conversation>(
        "GET",
        `/api/conversations/${conversation.id}`,
      );
      return fresh?.status ?? conversation.status ?? null;
    } catch {
      return conversation.status ?? null;
    }
  }

  /** The id, once known — for internal callers that already awaited the open. */
  get id(): string | null {
    return this.conversationIdValue;
  }
}

/** A `sandbox`/`terminate` stage event that means no turn event will arrive. */
function isConversationOver(event: LogEvent): boolean {
  if (event.kind !== "stage") return false;
  if (event.stage === "terminate") return true;
  if (event.stage === "sandbox" && event.state && TERMINAL_CONVERSATION_STATUSES.has(event.state)) {
    return true;
  }
  return false;
}

/** Mark a promise as handled without changing what it settles to. */
function hushed<T>(promise: Promise<T>): Promise<T> {
  promise.catch(() => {});
  return promise;
}
