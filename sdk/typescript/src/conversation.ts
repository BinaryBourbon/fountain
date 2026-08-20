import type { HttpClient } from "./http.ts";
import type { Conversation as ConversationRecord, LogEvent, Turn } from "./types.ts";
import { Run, type RunOptions } from "./run.ts";
import { streamEvents, type StreamOptions } from "./sse.ts";
import { conversationUrl } from "./config.ts";

export interface SendOptions extends RunOptions {
  /** Images to attach to the prompt, as the API's `ImageInput` shape. */
  images?: unknown[];
}

/**
 * A conversation you already have — the sandbox is still there, and so is
 * everything the agent learned in it.
 *
 * This is the piece no stateless agent API has. `resume(id).send(...)` costs
 * one prompt, not a re-explanation of the whole task, because the machine, the
 * checkout and the session are exactly where the last turn left them.
 */
export class Conversation {
  readonly id: string;

  private readonly http: HttpClient;
  /** Where the log feed has been read to, so a follow-up skips the history. */
  private cursor: number;

  constructor(http: HttpClient, id: string, cursor = 0) {
    this.http = http;
    this.id = id;
    this.cursor = cursor;
  }

  /** Where a human watches this conversation. */
  get url(): string {
    return conversationUrl(this.id, this.http.config);
  }

  /** The conversation record: status, agent, turn count. */
  async get(): Promise<ConversationRecord> {
    return this.http.data<ConversationRecord>("GET", `/api/conversations/${this.id}`);
  }

  async status(): Promise<ConversationRecord["status"]> {
    return (await this.get()).status;
  }

  async turns(): Promise<Turn[]> {
    return this.http.list<Turn>(`/api/conversations/${this.id}/turns`);
  }

  /** Send the next turn. Returns a `Run` — await it, or stream it. */
  send(prompt: string, options: SendOptions = {}): Run {
    const body: Record<string, unknown> = { prompt };
    if (options.images?.length) body.images = options.images;

    const run = new Run(
      this.http,
      {
        start: async () => {
          // The cursor and the turn number both have to be taken *before* the
          // prompt goes in, or we race the events it produces.
          const after = this.cursor > 0 ? this.cursor : await this.discoverCursor();
          const turnNumber = (await this.lastTurnNumber()) + 1;
          await this.http.request("POST", `/api/conversations/${this.id}/prompts`, { body });
          const conversation = await this.get();
          return { conversation, turnNumber, after };
        },
      },
      options,
    );

    // Keep the conversation's cursor moving as the run consumes the feed, so
    // the next send starts where this one stopped.
    void run
      .finally(() => {
        if (run.cursor > this.cursor) this.cursor = run.cursor;
      })
      .catch(() => {});

    return run;
  }

  /** Ask the agent to stop the turn it is on. The sandbox stays up. */
  async interrupt(): Promise<void> {
    await this.http.request("POST", `/api/conversations/${this.id}/interrupt`);
  }

  /** Tear the sandbox down. Nothing resumes after this. */
  async terminate(): Promise<void> {
    await this.http.request("POST", `/api/conversations/${this.id}/terminate`);
  }

  /** Delete the conversation and its history. */
  async delete(): Promise<void> {
    await this.http.request("DELETE", `/api/conversations/${this.id}`);
  }

  /**
   * The raw log feed, reconnecting on its own. Everything, from `after`
   * onwards, of every turn — `run`/`send` is the filtered view of this.
   */
  events(options: StreamOptions = {}): AsyncIterable<LogEvent> {
    return streamEvents(this.http, this.id, options);
  }

  /** One page of the log feed as JSON, for a client that would rather poll. */
  async eventPage(after = 0, limit = 1000): Promise<{ events: LogEvent[]; nextCursor: number; hasMore: boolean }> {
    const out = await this.http.request<{ data?: LogEvent[]; meta?: Record<string, unknown> }>(
      "GET",
      `/api/conversations/${this.id}/events`,
      { query: { after, limit, blocks: "true" } },
    );
    const meta = out?.meta ?? {};
    return {
      events: out?.data ?? [],
      nextCursor: typeof meta.next_cursor === "number" ? meta.next_cursor : after,
      hasMore: Boolean(meta.has_more),
    };
  }

  private async lastTurnNumber(): Promise<number> {
    const turns = await this.turns();
    return turns.reduce((max, turn) => Math.max(max, Number(turn.turn_number) || 0), 0);
  }

  /**
   * Find the end of the log feed cheaply.
   *
   * A cold `resume().send()` has no cursor, and starting from 0 would replay
   * every event of every earlier turn before reaching ours. Draining the
   * `stage` stream (`wait=false`) is a few rows for even a long conversation,
   * and its ids are the same global ids the full feed uses.
   */
  private async discoverCursor(): Promise<number> {
    let last = 0;
    try {
      for await (const event of streamEvents(this.http, this.id, {
        streams: "stage",
        wait: false,
        maxRetries: 0,
      })) {
        if (typeof event.id === "number" && event.id > last) last = event.id;
      }
    } catch {
      // Not worth failing a send over; 0 replays, which is correct if noisy.
      return 0;
    }
    this.cursor = last;
    return last;
  }
}
