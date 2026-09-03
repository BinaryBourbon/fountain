import { Fountain } from "@agentshit/fountain-sdk";

const fountain = new Fountain();
const run = await fountain.run(
  "Which operating system and working directory are you in? Answer in one sentence.",
  { agent: "$FOUNTAIN_AGENT_NAME" },
);

console.log(run.text);
