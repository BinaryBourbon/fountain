import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { FakeFountain } from "./server.ts";
import { Fountain } from "../src/index.ts";
import {
  NotFoundError,
  ResolutionError,
  SubscriptionRequiredError,
  TimeoutError,
} from "../src/errors.ts";

let fake: FakeFountain;
let baseUrl: string;

const client = (): Fountain =>
  new Fountain({ baseUrl, apiKey: "fk_test", appUrl: "https://app.example/fountain" });

before(async () => {
  fake = new FakeFountain();
  baseUrl = await fake.start();
});

after(async () => {
  await fake.stop();
});

beforeEach(() => {
  fake.conversations.clear();
  fake.requests.length = 0;
  fake.onTurn = null;
  fake.dieAfterEvents = null;
  fake.failNextWith = null;
  fake.onAnswer = null;
  fake.answers.length = 0;
});

describe("run", () => {
  test("reapplies conversation bindings and preserves explicit nulls", async () => {
    const conversation = fake.createConversation({ agent_id: "old" });
    const result = await client().resume(conversation.id).reapply({
      agentId: "new",
      environmentId: null,
      vaultId: "vault-2",
    });

    assert.equal(result.id, conversation.id);
    const request = fake.requests.find((r) => r.path.endsWith("/reapply"));
    assert.deepEqual(request?.body, {
      agent_id: "new",
      environment_id: null,
      vault_id: "vault-2",
    });
  });

  test("resolves names, opens a conversation and returns the answer", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.scriptTurn(conversation.id, {
        turnNumber,
        turnId: "t1",
        tools: ["Bash", "Edit"],
        text: ["Opened ", "PR #12."],
      });
    };

    const run = await client().run("upgrade phoenix", {
      agent: "reposage",
      vault: "github-bot",
      environment: "monorepo",
    });

    assert.equal(run.text, "Opened PR #12.");
    assert.deepEqual(run.toolsUsed, ["Bash", "Edit"]);
    assert.equal(run.state, "done");
    assert.equal(run.turnNumber, 1);
    assert.equal(run.reason, "end_turn");
    assert.equal(run.url, `https://app.example/fountain/#/c/${run.conversationId}`);

    // The names went to the wire as ids, and the prompt carried no secret.
    const create = fake.requests.find((r) => r.method === "POST" && r.path === "/api/conversations");
    assert.deepEqual(create?.body, {
      agent_id: "11111111-1111-1111-1111-111111111111",
      prompt: "upgrade phoenix",
      vault_id: "aaaaaaaa-1111-1111-1111-111111111111",
      environment_id: "bbbbbbbb-1111-1111-1111-111111111111",
    });
  });

  test("an unknown agent name names the ones that exist", async () => {
    await assert.rejects(
      async () => {
        await client().run("hi", { agent: "repossage" });
      },
      (error: unknown) => {
        assert.ok(error instanceof ResolutionError);
        assert.match(error.message, /No agent named "repossage"/);
        assert.match(error.message, /reporter, reposage/);
        return true;
      },
    );
  });

  test("an agent id is used as-is, without listing the account", async () => {
    fake.onTurn = (c, n) => fake.scriptTurn(c.id, { turnNumber: n, turnId: "t1", text: ["ok"] });
    const run = await client().run("hi", { agent: "11111111-1111-1111-1111-111111111111" });
    assert.equal(run.text, "ok");
    assert.equal(fake.requests.filter((r) => r.path === "/api/agents").length, 0);
  });

  test("streams text while the turn runs, and awaits the same run", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.scriptTurn(conversation.id, {
        turnNumber,
        turnId: "t1",
        text: ["Look", "ing at ", "the repo."],
      });
    };

    const run = client().run("look", { agent: "reposage" });
    const chunks: string[] = [];
    for await (const chunk of run.textStream) chunks.push(chunk);

    assert.deepEqual(chunks, ["Look", "ing at ", "the repo."]);
    const result = await run;
    assert.equal(result.text, "Looking at the repo.");
  });

  test("iterating yields lifecycle events in order", async () => {
    fake.onTurn = (c, n) =>
      fake.scriptTurn(c.id, { turnNumber: n, turnId: "t1", tools: ["Read"], text: ["done"] });

    const run = client().run("go", { agent: "reposage" });
    const types: string[] = [];
    for await (const event of run) {
      if (event.type === "event" || event.type === "block") continue;
      types.push(event.type);
    }
    assert.deepEqual(types, ["conversation", "turn-start", "tool", "text", "turn-end"]);
  });

  test("a failed turn is a result, not an exception", async () => {
    fake.onTurn = (c, n) =>
      fake.scriptTurn(c.id, { turnNumber: n, turnId: "t1", text: ["boom"], state: "failed" });

    const run = await client().run("go", { agent: "reposage" });
    assert.equal(run.state, "failed");
    assert.equal(run.text, "boom");
  });

  test("output from another turn is not this turn's answer", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      // A turn that was already running when we attached.
      fake.emit(conversation.id, {
        kind: "output",
        stream: "acp",
        turn_id: "older",
        blocks: [{ kind: "text", body: "leftovers from turn 0" }],
      });
      fake.scriptTurn(conversation.id, { turnNumber, turnId: "t1", text: ["mine"] });
    };

    const run = await client().run("go", { agent: "reposage" });
    assert.equal(run.text, "mine");
  });

  test("a stdout runtime joins rows as paragraphs, acp joins chunks", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.scriptTurn(conversation.id, {
        turnNumber,
        turnId: "t1",
        text: ["first line", "second line"],
        stream: "stdout",
      });
    };
    const legacy = await client().run("go", { agent: "reposage" });
    assert.equal(legacy.text, "first line\n\nsecond line");
  });

  test("text after a tool call starts a new paragraph", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      const turnId = "t1";
      fake.emit(conversation.id, {
        kind: "stage",
        stage: "turn",
        state: "started",
        stream: "stage",
        data: JSON.stringify({ turn_number: turnNumber, turn_id: turnId }),
      });
      fake.emit(conversation.id, {
        kind: "output",
        stream: "acp",
        turn_id: turnId,
        blocks: [{ kind: "text", body: "Reading it." }],
      });
      fake.emit(conversation.id, {
        kind: "output",
        stream: "acp",
        turn_id: turnId,
        blocks: [{ kind: "tool_use", name: "Read" }],
      });
      fake.emit(conversation.id, {
        kind: "output",
        stream: "acp",
        turn_id: turnId,
        blocks: [{ kind: "text", body: "It's a Phoenix app." }],
      });
      fake.emit(conversation.id, {
        kind: "stage",
        stage: "turn",
        state: "done",
        stream: "stage",
        data: JSON.stringify({ turn_number: turnNumber, turn_id: turnId }),
      });
    };

    const run = await client().run("go", { agent: "reposage" });
    assert.equal(run.text, "Reading it.\n\nIt's a Phoenix app.");
  });

  test("a dead connection mid-turn resumes from the last event id", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.scriptTurn(conversation.id, {
        turnNumber,
        turnId: "t1",
        text: ["one ", "two ", "three"],
      });
    };
    // Kill the first connection after the turn-start and the first chunk.
    fake.dieAfterEvents = 2;

    const run = await client().run("go", { agent: "reposage" });

    assert.equal(run.text, "one two three");
    const streams = fake.requests.filter((r) => r.path.endsWith("/stream"));
    assert.equal(streams.length, 2, "should have reconnected exactly once");
    // It resumed at the last event it actually saw — not at 0, which would
    // have replayed "one " and doubled it in the answer.
    const secondEventId = fake.conversations.get(run.conversationId)?.events[1]?.id;
    assert.equal(streams[1]?.headers["last-event-id"], String(secondEventId));
  });

  test("timing out says where the work still is", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.emit(conversation.id, {
        kind: "stage",
        stage: "turn",
        state: "started",
        stream: "stage",
        data: JSON.stringify({ turn_number: turnNumber, turn_id: "t1" }),
      });
      fake.emit(conversation.id, {
        kind: "output",
        stream: "acp",
        turn_id: "t1",
        blocks: [{ kind: "text", body: "thinking..." }],
      });
      // ...and never finishes.
    };

    await assert.rejects(
      async () => {
        await client().run("go", { agent: "reposage", timeoutMs: 150 });
      },
      (error: unknown) => {
        assert.ok(error instanceof TimeoutError);
        assert.equal(error.partialText, "thinking...");
        assert.match(error.message, /still running/);
        assert.ok(error.conversationId.startsWith("conv-"));
        return true;
      },
    );
  });

  test("a conversation that dies under the turn ends the wait, with the reason", async () => {
    // provision/failed is the real shape: the server stops, so no turn event
    // is ever coming. Waiting for one would hang forever.
    fake.onTurn = (conversation) => {
      fake.failConversation(conversation.id, "provision deadline exceeded");
    };

    const run = await client().run("go", { agent: "reposage" });
    assert.equal(run.state, "failed");
    assert.equal(run.status, "failed");
    assert.match(String(run.reason), /provision deadline exceeded/);
  });

  test("a failure stage on a conversation that is still alive is not the end", async () => {
    // setup/failed does not necessarily stop the conversation, which is why
    // the SDK asks for the status rather than trusting the stage name.
    fake.onTurn = (conversation, turnNumber) => {
      fake.emit(conversation.id, {
        kind: "stage",
        stage: "setup",
        state: "failed",
        stream: "stage",
        data: JSON.stringify({ exit_code: 1 }),
      });
      fake.scriptTurn(conversation.id, { turnNumber, turnId: "t1", text: ["carried on anyway"] });
    };

    const run = await client().run("go", { agent: "reposage", timeoutMs: 5_000 });
    assert.equal(run.state, "done");
    assert.equal(run.text, "carried on anyway");
  });

  test("a torn-down sandbox ends the wait instead of hanging", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.emit(conversation.id, {
        kind: "stage",
        stage: "turn",
        state: "started",
        stream: "stage",
        data: JSON.stringify({ turn_number: turnNumber, turn_id: "t1" }),
      });
      conversation.status = "terminated";
      fake.emit(conversation.id, { kind: "stage", stage: "terminate", state: "done", stream: "stage" });
    };

    const run = await client().run("go", { agent: "reposage", timeoutMs: 2_000 });
    assert.equal(run.state, "failed");
    assert.equal(run.status, "terminated");
    assert.equal(run.text, "");
  });
});

describe("resume and send", () => {
  test("a follow-up is turn 2 in the same sandbox", async () => {
    fake.onTurn = (c, n) => fake.scriptTurn(c.id, { turnNumber: n, turnId: `t${n}`, text: [`answer ${n}`] });

    const fountain = client();
    const first = await fountain.run("first", { agent: "reposage" });
    const second = await fountain.resume(first.conversationId).send("second");

    assert.equal(second.turnNumber, 2);
    assert.equal(second.text, "answer 2");
    assert.equal(second.conversationId, first.conversationId);
  });

  test("a cold resume skips the earlier turns' events", async () => {
    fake.onTurn = (c, n) => fake.scriptTurn(c.id, { turnNumber: n, turnId: `t${n}`, text: [`answer ${n}`] });

    const first = await client().run("first", { agent: "reposage" });
    fake.requests.length = 0;

    // A different process entirely: no memory of where the feed got to.
    const second = await client().resume(first.conversationId).send("second");
    assert.equal(second.text, "answer 2");

    const streams = fake.requests.filter((r) => r.path.endsWith("/stream"));
    const drain = streams.find((r) => r.method === "GET");
    assert.ok(drain, "should have drained the stage stream to find the cursor");
    const live = streams.at(-1);
    assert.ok(Number(live?.headers["last-event-id"]) > 0, "the live stream resumes past the history");
  });
});

describe("errors", () => {
  test("402 carries the upgrade url", async () => {
    fake.failNextWith = { status: 402, body: { error: "insufficient_credits", upgrade_url: "/account/billing" } };
    await assert.rejects(
      async () => {
        await client().run("go", { agent: "11111111-1111-1111-1111-111111111111" });
      },
      (error: unknown) => {
        assert.ok(error instanceof SubscriptionRequiredError);
        assert.equal(error.status, 402);
        assert.equal(error.code, "insufficient_credits");
        assert.equal(error.upgradeUrl, "/account/billing");
        return true;
      },
    );
  });

  test("a conversation that is not ours is a NotFoundError", async () => {
    await assert.rejects(
      () => client().resume("conv-nope").get(),
      (error: unknown) => {
        assert.ok(error instanceof NotFoundError);
        assert.match(error.message, /wrong id, or it belongs to another account/);
        return true;
      },
    );
  });

  // An `ask` policy holds the tool call until somebody answers, and denies it
  // when nobody does. The SDK has to both surface the question and be able to
  // answer it, or an `ask` agent silently does less than it was asked to.
  test("a held tool call is surfaced, answered, and the turn then finishes", async () => {
    fake.onTurn = (conversation) => {
      fake.emit(conversation.id, {
        kind: "stage",
        stage: "turn",
        state: "started",
        stream: "stage",
        data: JSON.stringify({ turn_number: 1, turn_id: "t1" }),
      });
      fake.emit(conversation.id, {
        kind: "output",
        stream: "acp",
        turn_id: "t1",
        blocks: [
          {
            kind: "permission_request",
            request_id: "req-7",
            summary: "Run the migration",
            options: [
              { optionId: "opt-allow", kind: "allow_once" },
              { optionId: "opt-deny", kind: "reject_once" },
            ],
          },
        ],
      });
      // and then nothing: the turn is held open until the answer arrives.
    };

    fake.onAnswer = (conversationId) => {
      fake.emit(conversationId, {
        kind: "output",
        stream: "acp",
        turn_id: "t1",
        blocks: [{ kind: "text", body: "Migration applied." }],
      });
      fake.emit(conversationId, {
        kind: "stage",
        stage: "turn",
        state: "done",
        stream: "stage",
        data: JSON.stringify({ turn_number: 1, turn_id: "t1" }),
      });
    };

    // A deadline so a regression fails in five seconds instead of hanging CI:
    // if the ask is never surfaced, nothing answers it and the turn never ends.
    const run = client().run("Migrate the database", { agent: "reposage", timeoutMs: 5_000 });

    let asked = 0;
    for await (const event of run) {
      if (event.type !== "permission") continue;
      asked++;
      assert.equal(event.request.summary, "Run the migration");
      const allow = event.request.options.find((option) => option.kind === "allow_once");
      assert.ok(allow, "the allow option must survive the trip");
      await run.answer(event.request.requestId, allow.optionId);
    }

    const result = await run;
    assert.equal(asked, 1);
    assert.equal(result.state, "done");
    assert.equal(result.text, "Migration applied.");
    assert.deepEqual(
      fake.answers.map((a) => [a.requestId, a.optionId]),
      [["req-7", "opt-allow"]],
    );
  });

  test("answering through a resumed conversation hits the same endpoint", async () => {
    fake.onTurn = (conversation, turnNumber) => {
      fake.scriptTurn(conversation.id, { turnNumber, turnId: "t1", text: ["ok"] });
    };
    const run = client().run("go", { agent: "reposage" });
    const id = await run.conversationId;
    await run;

    await client().resume(id).answer("req-9", "opt-deny");
    assert.deepEqual(fake.answers.at(-1), {
      conversationId: id,
      requestId: "req-9",
      optionId: "opt-deny",
    });
  });

  test("a missing key fails before any request", async () => {
    const bare = new Fountain({ baseUrl, apiKey: "", profile: "no-such-profile" });
    await assert.rejects(() => bare.me(), /No Fountain API key/);
  });

  // `/api/auth/me` answers with the identity itself, not `{data: …}`. Unwrapping
  // it returned `null` for a call that had succeeded, and nothing caught that
  // because the fake wrapped it too and the only test called `request()`.
  test("me() returns the identity, which the endpoint sends unenveloped", async () => {
    const me = await client().me();
    assert.equal(me.email, "test@example.com");
    assert.equal(me.role, "user");
    assert.ok(me.id, "an identity with no id means the envelope was unwrapped away");
  });
});

describe("escape hatch", () => {
  test("api reaches endpoints the SDK does not wrap", async () => {
    const me = await client().request<{ email: string }>("GET", "/api/auth/me");
    assert.equal(me.email, "test@example.com");
  });
});
