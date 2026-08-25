import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { FakeFountain } from "./server.ts";
import { Fountain, type AgentInput } from "../src/index.ts";
import { NotFoundError, ValidationError } from "../src/errors.ts";

let fake: FakeFountain;
let baseUrl: string;

const client = (): Fountain => new Fountain({ baseUrl, apiKey: "fk_test" });

before(async () => {
  fake = new FakeFountain();
  baseUrl = await fake.start();
});

after(async () => {
  await fake.stop();
});

beforeEach(() => {
  fake.agents = [
    { id: "11111111-1111-1111-1111-111111111111", name: "reposage", runtime: "claude", model: "opus" },
  ];
  fake.vaults = [{ id: "aaaaaaaa-1111-1111-1111-111111111111", name: "github-bot" }];
  fake.environments = [{ id: "bbbbbbbb-1111-1111-1111-111111111111", name: "monorepo" }];
  fake.secrets.clear();
  fake.requests.length = 0;
});

/** The definition the docs show — every field an agent has, in one object. */
const DEFINITION: AgentInput = {
  name: "reposage",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  description: "Reads a repository and answers questions about it",
  system: "You are a careful reader of other people's code.",
  environment_id: "bbbbbbbb-1111-1111-1111-111111111111",
  sandbox_provider: null,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: ["aaaaaaaa-1111-1111-1111-111111111111"],
  allowed_environment_ids: null,
  metadata: { team: "platform" },
};

describe("agents", () => {
  test("a whole definition goes to the wire flat, and comes back", async () => {
    const created = await client().agents.create({ ...DEFINITION, name: "newcomer" });

    assert.equal(created.name, "newcomer");
    assert.equal(created.runtime, "claude");

    const post = fake.requests.find((r) => r.method === "POST" && r.path === "/api/agents");
    // Flat attributes — not wrapped under an `agent` key, which the server rejects.
    assert.deepEqual(post?.body, { ...DEFINITION, name: "newcomer" });
  });

  test("a name is usable the moment it exists", async () => {
    const fountain = client();
    // Warm the resolver's memo so the create has something stale to invalidate.
    await fountain.agents.list();

    await fountain.agents.create({ ...DEFINITION, name: "brand-new" });
    const found = await fountain.agents.get("brand-new");
    assert.equal(found.name, "brand-new");
  });

  test("update touches only what it is given", async () => {
    const fountain = client();
    const updated = await fountain.agents.update("reposage", { model: "anthropic/claude-opus-5" });

    assert.equal(updated.model, "anthropic/claude-opus-5");
    assert.equal(updated.runtime, "claude", "untouched fields survive");

    const patch = fake.requests.find((r) => r.method === "PATCH");
    assert.deepEqual(patch?.body, { model: "anthropic/claude-opus-5" });
    assert.match(String(patch?.path), /^\/api\/agents\/11111111-/, "resolved the name to an id");
  });

  test("a rename is visible to the next lookup", async () => {
    const fountain = client();
    await fountain.agents.get("reposage");
    await fountain.agents.update("reposage", { name: "repo-sage" });

    const found = await fountain.agents.get("repo-sage");
    assert.equal(found.name, "repo-sage");
  });

  test("delete removes it, and the account listing agrees", async () => {
    const fountain = client();
    await fountain.agents.delete("reposage");
    assert.deepEqual(await fountain.agents.list(), []);
  });

  test("a definition without a name is rejected by the API, not the SDK", async () => {
    await assert.rejects(
      () => client().agents.create({ runtime: "claude", model: "anthropic/x" } as AgentInput),
      (error: unknown) => {
        assert.ok(error instanceof ValidationError);
        assert.equal(error.status, 422);
        return true;
      },
    );
  });
});

describe("environments and their secrets", () => {
  test("create an environment with repos and an egress allowlist", async () => {
    const env = await client().environments.create({
      name: "monorepo-ci",
      packages: { apt: ["ripgrep"] },
      env_vars: { CI: "true" },
      setup_script: "mix deps.get",
      networking_type: "limited",
      networking_config: { allowed_hosts: ["github.com", "hex.pm"] },
      repositories: [{ url: "https://github.com/BinaryBourbon/fountain", mount_path: "/work" }],
    });

    assert.equal(env.name, "monorepo-ci");
    const post = fake.requests.find((r) => r.method === "POST" && r.path === "/api/environments");
    assert.equal((post?.body as Record<string, unknown>).networking_type, "limited");
  });

  test("a secret goes in by name and never comes back out", async () => {
    const fountain = client();
    await fountain.environments.secrets.set("monorepo", "HEX_API_KEY", "super-secret");

    const listed = await fountain.environments.secrets.list("monorepo");
    assert.deepEqual(listed.map((s) => s.key), ["HEX_API_KEY"]);
    // The whole point: the SDK can put a credential in and cannot read it back.
    assert.equal(JSON.stringify(listed).includes("super-secret"), false);
  });

  test("setAll stores several, and delete takes the key", async () => {
    const fountain = client();
    await fountain.vaults.secrets.setAll("github-bot", {
      GITHUB_TOKEN: "ghp_x",
      GITHUB_USER: "bot",
    });
    assert.equal((await fountain.vaults.secrets.list("github-bot")).length, 2);

    await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
    assert.deepEqual(
      (await fountain.vaults.secrets.list("github-bot")).map((s) => s.key),
      ["GITHUB_TOKEN"],
    );

    const del = fake.requests.find((r) => r.method === "DELETE");
    assert.match(String(del?.path), /\/secrets\/GITHUB_USER$/, "the key is the path segment");
  });

  test("secrets on something that does not exist say so", async () => {
    await assert.rejects(
      () => client().vaults.secrets.set("aaaaaaaa-0000-0000-0000-000000000000", "K", "v"),
      NotFoundError,
    );
  });
});

describe("connections", () => {
  const CONNECTION = {
    id: "cccccccc-1111-1111-1111-111111111111",
    provider: "google",
    account_email: "me@example.com",
    scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.modify"],
    env_key: "GOOGLE_ACCESS_TOKEN",
    status: "active",
    expires_at: null,
    revoked_at: null,
    created_at: "2026-08-25T00:00:00Z",
    updated_at: "2026-08-25T00:00:00Z",
  };

  test("list, get, providers and delete", async () => {
    fake.connections = [CONNECTION];
    const fountain = client();

    const all = await fountain.connections.list();
    assert.equal(all.length, 1);
    assert.equal(all[0]?.account_email, "me@example.com");

    const one = await fountain.connections.get(CONNECTION.id);
    assert.equal(one.env_key, "GOOGLE_ACCESS_TOKEN");
    assert.equal(one.status, "active");

    const [google] = await fountain.connections.providers();
    assert.equal(google?.provider, "google");
    assert.match(String(google?.connect_url), /\/connections\/google\/start$/);

    await fountain.connections.delete(CONNECTION.id);
    assert.equal(fake.connections.length, 0);
    await assert.rejects(() => fountain.connections.get(CONNECTION.id), NotFoundError);
  });
});

describe("vaults", () => {
  test("create and read back", async () => {
    const fountain = client();
    const vault = await fountain.vaults.create({ name: "staging", description: "staging creds" });
    assert.equal(vault.name, "staging");
    assert.equal((await fountain.vaults.get("staging")).description, "staging creds");
  });
});
