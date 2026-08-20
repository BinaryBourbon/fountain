import { HttpClient, type FetchLike, type RequestOptions } from "./http.ts";
import { resolveConfig, type ConfigOptions, type ResolvedConfig } from "./config.ts";
import { Resolver } from "./resolve.ts";
import { Run, type RunOptions } from "./run.ts";
import { Conversation } from "./conversation.ts";
import { Agents, Environments, Vaults } from "./resources.ts";
import { Team, normalizeStreams } from "./team.ts";
import { streamPath, type StreamRequest } from "./sse.ts";
import type { AuthMe, Catalog, ConversationRecord, LogEvent, SearchHit } from "./types.ts";

export interface FountainOptions extends ConfigOptions {
  /** Swap the fetch implementation — a test server, a proxy, an instrumented one. */
  fetch?: FetchLike;
  /** Timeout for ordinary API calls, in ms. Streams are never timed out. */
  timeoutMs?: number;
}

export interface RunConfig extends RunOptions {
  /** The agent to run, by name or id. */
  agent: string;
  /**
   * A vault of secrets, by name or id. Its values win over the environment's
   * on a key collision, and they are attached when the sandbox spawns — the
   * prompt never carries them.
   */
  vault?: string;
  /** An environment to provision from instead of the agent's own, by name or id. */
  environment?: string;
  /** Display title for the conversation. */
  title?: string;
  /** Images to attach to the first prompt, as the API's `ImageInput` shape. */
  images?: unknown[];
  /**
   * Bind the conversation to an external channel. A second run with the same
   * channel, agent and vault continues that conversation instead of opening a
   * new one — how a chat harness keeps one thread on one sandbox.
   */
  channelId?: string;
  /** With `channelId`: open a new conversation anyway. */
  fresh?: boolean;
  /** Override the generated sandbox name. */
  spriteName?: string;
}

/**
 * A Fountain client.
 *
 * ```ts
 * const fountain = new Fountain();
 * const run = await fountain.run("Upgrade us to Phoenix 1.8 and open a PR", {
 *   agent: "reposage",
 *   vault: "github-bot",
 * });
 * console.log(run.text, run.url);
 * ```
 *
 * Credentials resolve the way the `fountain` CLI resolves them, so a script
 * inherits whatever already works in your terminal. See `resolveConfig`.
 */
export class Fountain {
  /** The raw HTTP client. Every endpoint this SDK does not wrap is still here. */
  readonly api: HttpClient;
  readonly config: ResolvedConfig;

  /** Define, read, change and delete agents. */
  readonly agents: Agents;
  /** Environments and their secrets. */
  readonly environments: Environments;
  /** Vaults and their secrets. */
  readonly vaults: Vaults;
  /** The team: teammates, their threads and their routines. */
  readonly team: Team;

  private readonly resolver: Resolver;

  constructor(options: FountainOptions = {}) {
    this.config = resolveConfig(options);
    this.api = new HttpClient(this.config, {
      fetch: options.fetch,
      timeoutMs: options.timeoutMs,
    });
    this.resolver = new Resolver(this.api);
    this.agents = new Agents(this.api, this.resolver);
    this.environments = new Environments(this.api, this.resolver);
    this.vaults = new Vaults(this.api, this.resolver);
    this.team = new Team(this.api, this.resolver);
  }

  /**
   * Run an agent on a prompt in a fresh sandbox.
   *
   * Returns immediately with a handle: `await` it for the finished answer,
   * `for await` it for events as they land, or read `.textStream`. The work
   * starts either way.
   */
  run(prompt: string, config: RunConfig): Run {
    const options: RunOptions = {
      timeoutMs: config.timeoutMs,
      signal: config.signal,
      collectEvents: config.collectEvents,
    };

    return new Run(
      this.api,
      {
        start: async () => {
          const [agent, vaultId, environmentId] = await Promise.all([
            this.resolver.resolve("/api/agents", "agent", config.agent),
            this.resolver.resolveId("/api/vaults", "vault", config.vault),
            this.resolver.resolveId("/api/environments", "environment", config.environment),
          ]);

          const body: Record<string, unknown> = { agent_id: agent.id };
          if (prompt) body.prompt = prompt;
          if (vaultId) body.vault_id = vaultId;
          if (environmentId) body.environment_id = environmentId;
          if (config.title) body.title = config.title;
          if (config.images?.length) body.images = config.images;
          if (config.channelId) body.channel_id = config.channelId;
          if (config.fresh) body.fresh = true;
          if (config.spriteName) body.sprite_name = config.spriteName;

          const conversation = await this.api.data<ConversationRecord>(
            "POST",
            "/api/conversations",
            { body },
          );

          // `channel_id` may have resumed an existing conversation, in which
          // case this prompt is not turn 1. Ask, rather than assume.
          const turnNumber = config.channelId ? await this.nextTurnNumber(conversation.id) : 1;
          return { conversation, turnNumber, after: 0 };
        },
      },
      options,
    );
  }

  /**
   * Pick a conversation back up. The sandbox is still there and so is the
   * agent's session — `send` costs one prompt, not a re-explanation.
   */
  resume(conversationId: string): Conversation {
    return new Conversation(this.api, conversationId);
  }

  /** The account's conversations, newest first. */
  async conversations(opts: { rootsOnly?: boolean } = {}): Promise<ConversationRecord[]> {
    return this.api.list<ConversationRecord>("/api/conversations", {
      query: { roots_only: opts.rootsOnly === false ? undefined : "true" },
    });
  }

  /** Who this key belongs to. The cheapest way to check a key works. */
  async me(): Promise<AuthMe> {
    return this.api.data<AuthMe>("GET", "/api/auth/me");
  }

  /**
   * The form vocabulary: the runtimes, models and providers this deployment
   * offers. A client that builds an agent form reads it from here rather than
   * hard-coding a list that goes stale on the next Fountain release.
   */
  async catalog(): Promise<Catalog> {
    return this.api.data<Catalog>("GET", "/api/catalog");
  }

  /** Full-text search across the caller's conversations. */
  async search(query: string, opts: { limit?: number } = {}): Promise<SearchHit[]> {
    return this.api.list<SearchHit>("/api/search", { query: { q: query, limit: opts.limit } });
  }

  /**
   * Every conversation the caller owns, on one connection.
   *
   * `team.stream()` is the same idea narrowed to the team. Use this when the
   * client cares about conversations that are not teammates' — a dashboard,
   * or a process watching work it spawned itself.
   */
  events(options: StreamRequest = {}): AsyncIterable<LogEvent> {
    return streamPath(this.api, "/api/events/stream", { blocks: true, ...normalizeStreams(options) });
  }

  /** Forget the memoized agent/vault/environment listings. */
  refresh(): void {
    this.resolver.clear();
  }

  /** Shorthand for `api.request`, for endpoints this SDK does not wrap. */
  request<T = unknown>(method: string, path: string, options?: RequestOptions): Promise<T> {
    return this.api.request<T>(method, path, options);
  }

  private async nextTurnNumber(conversationId: string): Promise<number> {
    const turns = await this.api.list<{ turn_number?: number }>(
      `/api/conversations/${conversationId}/turns`,
    );
    return turns.reduce((max, t) => Math.max(max, Number(t.turn_number) || 0), 0) + 1;
  }
}
