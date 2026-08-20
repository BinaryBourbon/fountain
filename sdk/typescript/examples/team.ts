/**
 * Hire a teammate, talk to it, and watch the whole team on one connection.
 *
 *   FOUNTAIN_API_KEY=... node examples/team.ts
 *
 * Creates a temporary agent and removes everything on the way out.
 */
import { Fountain } from "../src/node.ts";

const fountain = new Fountain();
const name = `sdk-team-${process.argv[2] ?? "demo"}`;
let conversationId: string | null = null;

try {
  await fountain.agents.create({
    name,
    runtime: "claude",
    model: "anthropic/claude-haiku-4-5",
    system: "You answer in one very short line.",
  });

  const teammate = await fountain.team.add(name, { name: "Smoke" });
  console.log(`hired ${teammate.name}`);

  // One connection for every teammate — a team UI's whole event source.
  const stop = new AbortController();
  const watching = (async () => {
    for await (const event of fountain.team.stream({ streams: ["stage"], signal: stop.signal })) {
      if (event.stage === "turn") console.log(`  · turn ${event.state}`);
    }
  })();

  const first = await fountain.team.message(name, "Reply with just the word PONG.");
  conversationId = first.conversationId;
  console.log(`turn ${first.turnNumber}: ${first.text}`);

  // The same thread, on the same computer: the teammate is durable.
  const second = await fountain.team.message(name, "Now reply with just the word PING.");
  console.log(`turn ${second.turnNumber}: ${second.text}`);

  stop.abort();
  await watching;

  // What a UI does when someone opens the thread.
  const conversation = fountain.resume(conversationId);
  console.log(`${(await conversation.history({ streams: ["acp", "stage"] })).length} events in the thread`);
  await conversation.markRead();
} finally {
  await fountain.team.remove(name).catch(() => {});
  if (conversationId) await fountain.resume(conversationId).terminate().catch(() => {});
  await fountain.agents.delete(name).catch(() => {});
  console.log("cleaned up");
}
