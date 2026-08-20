import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";

export const DEFAULT_BASE_URL = "https://fountain.inevitable.fyi";

/** Where a human reads a transcript. Fountain's own UI is a console (see CLAUDE.md). */
export const DEFAULT_APP_URL = "https://jakegaylor.com/fountain-conversations/";

export interface ResolvedConfig {
  baseUrl: string;
  apiKey: string;
  appUrl: string;
  /** Set when running inside a Fountain sandbox; stamps spawned conversations as children. */
  parentConversationId: string | undefined;
}

export interface ConfigOptions {
  /** Bearer token. Falls back to the environment, then `~/.fountain/credentials`. */
  apiKey?: string;
  /** Your Fountain deployment. Defaults to the hosted one. */
  baseUrl?: string;
  /** Credentials-file profile. Defaults to `$FOUNTAIN_PROFILE` or `default`. */
  profile?: string;
  /** Base of the conversations app, for `run.url`. `""` falls back to the API URL. */
  appUrl?: string;
}

function unquote(value: string): string {
  const v = (value ?? "").trim();
  if (v.length >= 2 && v[0] === v[v.length - 1] && (v[0] === '"' || v[0] === "'")) {
    return v.slice(1, -1).trim();
  }
  return v;
}

/**
 * Read one profile out of the INI-ish file `fountain auth login` writes.
 * Absent or unreadable is not an error — it just contributes nothing.
 */
function readCredentials(profile: string): Record<string, string> {
  const override = (process.env.FOUNTAIN_CREDENTIALS_FILE ?? "").trim();
  const path = override || join(homedir(), ".fountain", "credentials");
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return {};
  }

  const out: Record<string, string> = {};
  let section = "";
  for (const line of raw.split("\n")) {
    const text = line.trim();
    if (!text || text.startsWith("#") || text.startsWith(";")) continue;
    if (text.startsWith("[") && text.endsWith("]")) {
      section = text.slice(1, -1).trim();
      continue;
    }
    if (section !== profile) continue;
    const eq = text.indexOf("=");
    if (eq === -1) continue;
    out[text.slice(0, eq).trim()] = unquote(text.slice(eq + 1));
  }
  return out;
}

const env = (name: string): string => (process.env[name] ?? "").trim();

/**
 * Resolve credentials the way the `fountain` CLI does, so a script inherits
 * whatever already works in the terminal:
 *
 *   apiKey:  option → FOUNTAIN_API_KEY → FOUNTAIN_TOKEN → ~/.fountain/credentials
 *   baseUrl: option → FOUNTAIN_BASE_URL → ~/.fountain/credentials → hosted
 *
 * `FOUNTAIN_TOKEN` is what a Fountain sandbox exports for the agent inside it,
 * so an agent that reaches for this SDK delegates with the conversation-scoped
 * token it already has — and the conversations it starts are recorded as its
 * children.
 */
export function resolveConfig(options: ConfigOptions = {}): ResolvedConfig {
  const profile = (options.profile ?? "").trim() || env("FOUNTAIN_PROFILE") || "default";
  let creds: Record<string, string> | undefined;
  const credentials = (): Record<string, string> => (creds ??= readCredentials(profile));

  let apiKey = (options.apiKey ?? "").trim() || env("FOUNTAIN_API_KEY") || env("FOUNTAIN_TOKEN");
  if (!apiKey) apiKey = credentials().api_key ?? "";

  let baseUrl = (options.baseUrl ?? "").trim() || env("FOUNTAIN_BASE_URL");
  if (!baseUrl) baseUrl = credentials().base_url || DEFAULT_BASE_URL;

  const appUrl = options.appUrl !== undefined ? options.appUrl.trim() : env("FOUNTAIN_APP_URL") || DEFAULT_APP_URL;

  return {
    baseUrl: baseUrl.replace(/\/+$/, ""),
    apiKey,
    appUrl: appUrl.replace(/\/+$/, ""),
    parentConversationId: env("FOUNTAIN_CONVERSATION_ID") || undefined,
  };
}

/** The URL a human opens to watch this conversation. */
export function conversationUrl(conversationId: string, config: ResolvedConfig): string {
  if (!config.appUrl) return `${config.baseUrl}/api/conversations/${conversationId}`;
  return `${config.appUrl}/#/c/${conversationId}`;
}
