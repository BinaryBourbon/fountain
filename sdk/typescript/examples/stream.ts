/**
 * Watch a turn as it happens, then keep the conversation going.
 *
 *   FOUNTAIN_API_KEY=... node examples/stream.ts "<agent>"
 */
import { Fountain } from "../src/index.ts";

const agent = process.argv[2] ?? "smoke-runner";
const fountain = new Fountain();

const run = fountain.run("List the files in the repo root, then say how many there are.", {
  agent,
  // A vault's secrets are attached when the sandbox spawns — not sent here.
  // vault: "github-bot",
});

console.log(`watch: ${await run.url}\n`);

for await (const event of run) {
  switch (event.type) {
    case "turn-start":
      console.log("· the agent picked up the turn");
      break;
    case "tool":
      console.log(`· ${event.name}`);
      break;
    case "text":
      process.stdout.write(event.text);
      break;
    case "turn-end":
      console.log(`\n· ${event.state}`);
      break;
  }
}

const first = await run;

// The sandbox is still up, and the agent still knows what it just did.
const second = await fountain.resume(first.conversationId).send("Which of those is the largest?");
console.log(`\n${second.text}`);

await fountain.resume(first.conversationId).terminate();
