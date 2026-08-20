/**
 * The guided tour, runnable: an agent that clones a repo, makes a change and
 * opens a pull request — then a follow-up that amends the same PR.
 *
 *   FOUNTAIN_API_KEY=... GITHUB_TOKEN=... node examples/pull-request.ts \
 *     https://github.com/you/your-app
 *
 * Use a fine-grained token scoped to that one repository: the agent gets a
 * real credential. Everything created here is deleted on the way out.
 *
 * Full walkthrough: docs/tour.md
 */
import { Fountain } from "../src/node.ts";

const repo = process.argv[2];
const token = process.env.GITHUB_TOKEN;
if (!repo || !token) {
  console.error("usage: GITHUB_TOKEN=… node examples/pull-request.ts <https repo url>");
  process.exit(1);
}

const fountain = new Fountain();
const names = { environment: "tour-workspace", vault: "tour-github", agent: "tour-contributor" };
let conversationId: string | null = null;

try {
  const environment = await fountain.environments.create({
    name: names.environment,
    // `secret_key` names the secret the clone authenticates with. A private
    // repo without it fails to clone *inside the sandbox*: the conversation
    // starts anyway and the agent finds an empty directory.
    repositories: [{ url: repo, mount_path: "/work/app", secret_key: "GITHUB_TOKEN" }],
  });

  const vault = await fountain.vaults.create({ name: names.vault });
  await fountain.vaults.secrets.set(names.vault, "GITHUB_TOKEN", token); // the clone reads this
  await fountain.vaults.secrets.set(names.vault, "GH_TOKEN", token); // `gh` reads this

  await fountain.agents.create({
    name: names.agent,
    runtime: "claude",
    model: "anthropic/claude-sonnet-5",
    system:
      "You work in /work/app, a git repository. Make the smallest change that " +
      "satisfies the request, commit on a new branch, push, and open a pull request " +
      "with `gh`. Report the PR url and nothing else.",
    environment_id: environment.id,
    allowed_vault_ids: [vault.id],
  });

  const run = fountain.run(
    "Add a --version flag that prints 0.1.0 and exits. Update the README. Then open a pull request.",
    { agent: names.agent, vault: names.vault, timeoutMs: 15 * 60_000 },
  );
  for await (const event of run) {
    if (event.type === "tool") console.log("·", event.name);
  }
  const result = await run;
  conversationId = result.conversationId;
  console.log(`\n${result.text}\n`);

  // The sandbox is still up, on the branch the first turn made.
  const revision = await fountain
    .resume(result.conversationId)
    .send("Also accept -v as an alias for --version, and push it to the same PR.");
  console.log(`turn ${revision.turnNumber}: ${revision.text}`);
} finally {
  // The credential goes first, whatever happened above.
  await fountain.vaults.delete(names.vault).catch(() => {});
  if (conversationId) await fountain.resume(conversationId).terminate().catch(() => {});
  await fountain.agents.delete(names.agent).catch(() => {});
  await fountain.environments.delete(names.environment).catch(() => {});
  console.log("cleaned up");
}
