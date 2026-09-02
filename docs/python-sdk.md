# Python SDK

The Python SDK turns the conversation API and its event feed into one job:

```python
from fountain import Fountain

fountain = Fountain()
result = fountain.run(
    "Upgrade us to Phoenix 1.8 and open a PR",
    agent="reposage",
    vault="github-bot",
).result()

print(result.text)
print(result.url)
```

The source is in
[`sdk/python/`](https://github.com/BinaryBourbon/fountain/tree/main/sdk/python).
It supports Python 3.9 and newer and has no runtime dependencies.

```bash
pip install fountain-agent-sdk
```

## Credentials

`Fountain()` resolves credentials the same way as the CLI:

```text
api_key:  argument -> FOUNTAIN_API_KEY -> FOUNTAIN_TOKEN -> ~/.fountain/credentials
base_url: argument -> FOUNTAIN_BASE_URL -> ~/.fountain/credentials -> hosted Fountain
```

Use `Fountain(profile="work")` for another credentials-file profile. Inside a
Fountain sandbox, the client uses its conversation-scoped token and marks new
conversations as children of the current one.

## Waiting and streaming

`run()` starts work immediately and returns a `Run` handle. `result()` waits
for the finished turn. Iterating the handle streams lifecycle, text, thinking,
tool, block, and permission events from that same run.

```python
run = fountain.run("Review this repository", agent="reviewer")

for event in run:
    if event["type"] == "tool":
        print("->", event["name"])
    elif event["type"] == "text":
        print(event["text"], end="", flush=True)

result = run.result()
```

Use `run.text_stream` when you only need the answer text. Start several runs
before calling `result()` to provision and run them in parallel.

The handle is awaitable and asynchronously iterable too. The SDK keeps HTTP in
its background thread, so the wait does not block an asyncio event loop.

```python
result = await fountain.run("Review this repository", agent="reviewer")

run = fountain.run("Review another repository", agent="reviewer")
async for event in run:
    print(event)
```

A failed agent turn is a result with `state == "failed"`. A transport failure,
a rejected request, or an SDK timeout raises an exception. The timeout passed
to `run(..., timeout=300)` stops the SDK's wait in seconds; it does not stop the
agent. Call `run.interrupt()` to ask the agent to stop.

## Follow-ups

```python
first = fountain.run("Find every N+1 query", agent="reposage").result()
second = fountain.resume(first.conversation_id).send("Fix the worst three.").result()
```

The second turn uses the same sandbox, checkout, and agent session.

## Permission requests

An agent with an `ask` permission rule stops before a matching tool call. The
run emits a `permission` event with the options the runtime offered:

```python
for event in run:
    if event["type"] != "permission":
        continue

    request = event["request"]
    allow = next(
        option for option in request["options"]
        if option.get("kind") == "allow_once"
    )
    run.answer(request["request_id"], allow["option_id"])
```

You can also answer through `fountain.resume(conversation_id).answer(...)`
from another process.

## Resources

Agents, environments, and vaults have `list`, `get`, `create`, `update`, and
`delete`. Environment and vault secret values are write-only.

```python
environment = fountain.environments.create({
    "name": "fountain-ci",
    "packages": {"apt": ["ripgrep"]},
    "repositories": [{
        "url": "https://github.com/BinaryBourbon/fountain",
        "mount_path": "/work/fountain",
    }],
})

vault = fountain.vaults.create({"name": "github-bot"})
fountain.vaults.secrets.set("github-bot", "GITHUB_TOKEN", token)

agent = fountain.agents.create({
    "name": "reposage",
    "runtime": "claude",
    "model": "anthropic/claude-sonnet-5",
    "environment_id": environment["id"],
    "allowed_vault_ids": [vault["id"]],
})
```

Resource dictionaries keep the API's snake_case keys. You can use the same
definition in Python, the REST API, and a `fountain.yml` manifest.

## The team

```python
fountain.team.add("watchtower", name="Watchtower")
reply = fountain.team.message(
    "watchtower",
    "Any disks over 80%?",
).result()

fountain.team.schedules.create("watchtower", {
    "cron": "0 9 * * *",
    "prompt": "Check disk usage and say only what changed.",
})
```

`team.list`, `get`, `rename`, `remove`, `history`, `fresh_conversation`, and
`stream` cover the rest of the teammate lifecycle. `team.schedules` has the
five resource verbs and `run` for an immediate invocation.

## Sandboxes

List, inspect, and reset sandboxes through `sandboxes()`, `sandbox(id)`, and
`reset_sandbox(id)`. A full-scope key can also inspect a ready machine:

```python
command = fountain.exec_sandbox(
    sandbox_id,
    "git",
    args=["diff", "--stat"],
    cwd="/work/repository",
    timeout_ms=30_000,
)
print(command["output"], command["exit_code"])

file = fountain.read_sandbox_file(
    sandbox_id,
    "/work/repository/build.log",
)
print(file.data.decode())
```

The sandbox must be ready. These calls do not wake a suspended machine, and
they are allowed while the agent works. A command that writes changes the tree
beneath the agent.

## Errors and the raw API

Catch `ConversationBusyError`, `NotReadyError`, `QuotaExceededError`,
`ValidationError`, `AuthError`, or the base `FountainError`. Each one carries
`status`, `code`, `body`, `retry_after`, and `retryable`. A validation error
also exposes `field_errors`.

Endpoints without a wrapper stay available through the same authentication
and error handling:

```python
rows = fountain.request("GET", "/api/audit", query={"limit": 50})
```
