/**
 * The whole SDK in ten lines.
 *
 *   FOUNTAIN_API_KEY=... node examples/run.ts "<agent>" "<prompt>"
 */
import { Fountain } from "../src/index.ts";

const [agent = "smoke-runner", prompt = "Reply with the kernel name and nothing else."] =
  process.argv.slice(2);

const fountain = new Fountain();
const run = await fountain.run(prompt, { agent });

console.log(run.text);
console.log(`\n${run.state} · ${run.toolsUsed.join(", ") || "no tools"} · ${run.url}`);
