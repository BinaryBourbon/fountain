/**
 * Every failure the SDK raises is a `FountainError` or a subclass of one, so a
 * caller can `catch (e) { if (e instanceof FountainError) ... }` and get the
 * status, the machine-readable code and the parsed body without reaching for
 * the response object.
 */
export class FountainError extends Error {
  /** HTTP status, or 0 for a transport-level failure. */
  readonly status: number;
  /** The API's `error` field when it sent one (`subscription_required`, ...). */
  readonly code: string | undefined;
  /** The parsed response body, whatever shape it had. */
  readonly body: unknown;

  constructor(
    message: string,
    opts: { status?: number; code?: string; body?: unknown; cause?: unknown } = {},
  ) {
    super(message, opts.cause !== undefined ? { cause: opts.cause } : undefined);
    this.name = new.target.name;
    this.status = opts.status ?? 0;
    this.code = opts.code;
    this.body = opts.body;
  }
}

/** No API key, or the key was rejected (401). */
export class AuthError extends FountainError {}

/** The account has no active subscription (402). `upgradeUrl` is where to fix it. */
export class SubscriptionRequiredError extends FountainError {
  readonly upgradeUrl: string | undefined;
  constructor(message: string, opts: ConstructorParameters<typeof FountainError>[1] = {}) {
    super(message, opts);
    const body = opts.body as Record<string, unknown> | undefined;
    this.upgradeUrl =
      body && typeof body === "object" && typeof body.upgrade_url === "string"
        ? body.upgrade_url
        : undefined;
  }
}

/** Wrong id, or it belongs to another account — Fountain does not distinguish (404). */
export class NotFoundError extends FountainError {}

/** The request was well-formed but rejected (422). */
export class ValidationError extends FountainError {}

/** Too many requests (429). */
export class RateLimitError extends FountainError {}

/**
 * `run`/`send` gave up waiting. The turn is still running in the sandbox —
 * `fountain.resume(conversationId)` picks it back up.
 */
export class TimeoutError extends FountainError {
  readonly conversationId: string;
  /** Whatever the agent had said by the deadline. */
  readonly partialText: string;
  constructor(message: string, conversationId: string, partialText: string) {
    super(message);
    this.conversationId = conversationId;
    this.partialText = partialText;
  }
}

/** A name that matched no agent/vault/environment, or matched more than one. */
export class ResolutionError extends FountainError {}

const HINTS: Record<number, string> = {
  400: "bad request",
  401: "unauthorized — check the API key",
  402: "payment required — the account has no active subscription",
  403: "forbidden — the key may lack the scope for this call",
  404: "not found — wrong id, or it belongs to another account",
  409: "conflict",
  422: "rejected",
  429: "rate limited — retry shortly",
};

/** Map an HTTP failure onto the right error class, with a message worth reading. */
export function errorForStatus(
  status: number,
  body: unknown,
  method: string,
  url: string,
): FountainError {
  let detail = "";
  let code: string | undefined;
  if (body && typeof body === "object") {
    const b = body as Record<string, unknown>;
    const err = b.error ?? b.errors ?? b.message;
    if (typeof err === "string") {
      detail = err;
      code = typeof b.error === "string" ? b.error : undefined;
    } else if (err !== undefined) {
      detail = JSON.stringify(err);
    }
  } else if (typeof body === "string" && body.trim()) {
    detail = body.trim().slice(0, 300);
  }

  const message = [`HTTP ${status}`, HINTS[status], detail, `(${method} ${url})`]
    .filter(Boolean)
    .join(" ");
  const opts = { status, code, body };

  switch (status) {
    case 401:
      return new AuthError(message, opts);
    case 402:
      return new SubscriptionRequiredError(message, opts);
    case 404:
      return new NotFoundError(message, opts);
    case 422:
      return new ValidationError(message, opts);
    case 429:
      return new RateLimitError(message, opts);
    default:
      return new FountainError(message, opts);
  }
}
