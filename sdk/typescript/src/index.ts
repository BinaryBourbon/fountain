export { Fountain, type FountainOptions, type RunConfig } from "./client.ts";
export { Run, type RunOptions } from "./run.ts";
export { Conversation, type SendOptions } from "./conversation.ts";
export { HttpClient, type FetchLike, type RequestOptions } from "./http.ts";
export {
  resolveConfig,
  conversationUrl,
  DEFAULT_BASE_URL,
  DEFAULT_APP_URL,
  type ConfigOptions,
  type ResolvedConfig,
} from "./config.ts";
export { streamEvents, parseSse, type StreamOptions, type SseMessage } from "./sse.ts";
export { TurnFollower } from "./turn.ts";
export {
  FountainError,
  AuthError,
  SubscriptionRequiredError,
  NotFoundError,
  ValidationError,
  RateLimitError,
  TimeoutError,
  ResolutionError,
} from "./errors.ts";
export type {
  Agent,
  Block,
  Conversation as ConversationRecord,
  ConversationStatus,
  LogEvent,
  NamedResource,
  RunEvent,
  RunResult,
  Turn,
  TurnState,
} from "./types.ts";

import { Fountain } from "./client.ts";
export default Fountain;
