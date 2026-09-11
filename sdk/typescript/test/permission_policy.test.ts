import { test, describe } from "node:test";
import assert from "node:assert/strict";
import type { components } from "../src/generated/openapi.ts";

type AgentRequest = components["schemas"]["AgentRequest"];
type PermissionPolicy = NonNullable<AgentRequest["permission_policy"]>;

// `ask_timeout` is the one key of a permission policy whose value is not a
// verdict (#1635). The generated type is an intersection of the named
// property with the index signature, so the index signature has to admit a
// number: with a verdict-only one, `ask_timeout` narrows to `never` and the
// key is untypeable even though the server accepts it.
describe("permission_policy", () => {
  test("ask_timeout takes a number of seconds", () => {
    const policy: PermissionPolicy = { ask_timeout: 3600 };

    // Read it back through the named property, which is what would be `never`.
    const seconds: number | undefined = policy.ask_timeout;
    assert.equal(seconds, 3600);
  });

  test("a tool key takes a verdict, beside the timeout", () => {
    const policy: PermissionPolicy = {
      default: "auto_allow",
      execute: "ask",
      ask_timeout: 172_800,
    };

    assert.equal(policy.execute, "ask");
    assert.equal(policy.ask_timeout, 172_800);
  });

  test("a value that is neither a verdict nor a number is refused", () => {
    // @ts-expect-error "maybe" is not a verdict.
    const policy: PermissionPolicy = { execute: "maybe" };
    assert.ok(policy);
  });
});
