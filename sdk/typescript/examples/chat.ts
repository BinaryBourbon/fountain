/**
 * The data layer of a messaging client for your team, in one file.
 *
 *   FOUNTAIN_API_KEY=... node examples/chat.ts
 *
 * Every piece here is what a roster-and-threads UI actually needs: a roster
 * row, a live router for the team's one connection, and a transcript folded
 * out of server-parsed blocks. The docs walk through it at
 * https://managoat.com/docs/build/team-chat — this file is the
 * copy CI typechecks, so the page cannot drift from the SDK.
 *
 * Creates a temporary agent and removes everything on the way out.
 */
import { Fountain } from "../src/node.ts";
import type { Block, LogEvent, TeamEvent, Teammate, Turn } from "../src/index.ts";

// ── what a roster row shows ──────────────────────────────────────────────────

interface RosterRow {
  agentId: string;
  name: string;
  status: string;
  line: string;
  who: "you" | "them" | "typing" | undefined;
  unread: boolean;
}

/** One `team.list()` call fills a row completely. */
function rosterRow(teammate: Teammate): RosterRow {
  return {
    agentId: teammate.agent_id,
    name: teammate.name,
    status: teammate.presence.label,
    line: teammate.preview?.text ?? "",
    who: teammate.preview?.kind,
    unread: teammate.unread,
  };
}

// ── the transcript ───────────────────────────────────────────────────────────

type Part = { kind: "text" | "thinking" | "tools"; body: string; tools: string[] };
type Bubble = { from: "you"; text: string } | { from: "them"; parts: Part[] };

/**
 * A reply as a chat bubble wants it: adjacent prose joined, a run of tool
 * calls collapsed into one line.
 *
 * The blocks come from the server (`?blocks=true`, which `history()` sets),
 * so this never parses a runtime's own dialect.
 */
function fold(blocks: Block[]): Part[] {
  const out: Part[] = [];
  for (const block of blocks) {
    const last = out.at(-1);
    if (block.kind === "text" || block.kind === "thinking") {
      if (last?.kind === block.kind) last.body += block.body ?? "";
      else out.push({ kind: block.kind, body: block.body ?? "", tools: [] });
    } else if (block.kind === "tool_use") {
      if (last?.kind === "tools") last.tools.push(block.name ?? "a tool");
      else out.push({ kind: "tools", body: "", tools: [block.name ?? "a tool"] });
    }
  }
  return out;
}

/** Each turn is a pair of bubbles: what was said, and what was done about it. */
function bubbles(turns: Turn[], events: LogEvent[]): Bubble[] {
  const byTurn = new Map<string, Block[]>();
  for (const event of events) {
    if (!event.turn_id) continue;
    const blocks = byTurn.get(event.turn_id) ?? [];
    blocks.push(...(event.blocks ?? []));
    byTurn.set(event.turn_id, blocks);
  }

  return turns.flatMap((turn): Bubble[] => [
    { from: "you", text: turn.prompt },
    { from: "them", parts: fold(byTurn.get(turn.id) ?? []) },
  ]);
}

// ── the one connection ───────────────────────────────────────────────────────

interface Handlers {
  rosterChanged(): void;
  typing(agentId: string, on: boolean): void;
  replied(agentId: string, conversationId: string): void;
}

/**
 * Route the whole team's events. Payloads carry `conversation_id` and
 * `agent_id`, so a row is found without a lookup; an event with neither is a
 * `team` or `schedule` notice telling the client to re-list.
 */
function route(event: TeamEvent, on: Handlers): void {
  if (!event.agent_id) return on.rosterChanged();
  if (event.stage !== "turn") return;
  if (event.state === "started") on.typing(event.agent_id, true);
  if (event.state === "done") {
    on.typing(event.agent_id, false);
    if (event.conversation_id) on.replied(event.agent_id, event.conversation_id);
  }
}

// ── exercise all of it against a live instance ───────────────────────────────

const fountain = new Fountain();
const name = `sdk-chat-${process.argv[2] ?? "demo"}`;
let conversationId: string | null = null;

try {
  // The form vocabulary, so a "new teammate" dialog is never a stale list.
  const catalog = await fountain.catalog();
  const model = catalog.models.claude?.[0] ?? "anthropic/claude-haiku-4-5";

  await fountain.agents.create({
    name,
    runtime: "claude",
    model,
    description: "Created by the Fountain SDK's chat example",
    system: "You answer in one very short line.",
  });
  await fountain.team.add(name, { name: "Watchtower" });

  const stop = new AbortController();
  const watching = (async () => {
    for await (const event of fountain.team.stream({ streams: ["stage"], signal: stop.signal })) {
      route(event, {
        rosterChanged: () => console.log("  · roster changed — re-list"),
        typing: (_agentId, on) => console.log(`  · ${on ? "typing…" : "done"}`),
        replied: (_agentId, id) => console.log(`  · reply in ${id}`),
      });
    }
  })();

  for (const row of (await fountain.team.list()).map(rosterRow)) {
    console.log(`${row.unread ? "●" : " "} ${row.name} — ${row.status}  ${row.line}`);
  }

  const reply = await fountain.team.message(name, "Reply with just the word PONG.");
  conversationId = reply.conversationId;

  stop.abort();
  await watching;

  // What the UI does when someone opens the thread.
  const conversation = fountain.resume(conversationId);
  const [turns, events] = await Promise.all([
    conversation.turns(),
    conversation.history({ streams: ["acp", "stdout"] }),
  ]);
  await conversation.markRead();

  for (const bubble of bubbles(turns, events)) {
    if (bubble.from === "you") console.log(`you  › ${bubble.text}`);
    else
      for (const part of bubble.parts) {
        if (part.kind === "tools") console.log(`them › [ran ${part.tools.join(", ")}]`);
        else console.log(`them › ${part.body.trim()}`);
      }
  }
} finally {
  await fountain.team.remove(name).catch(() => {});
  if (conversationId) await fountain.resume(conversationId).terminate().catch(() => {});
  await fountain.agents.delete(name).catch(() => {});
  console.log("cleaned up");
}
