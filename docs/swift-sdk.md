# Swift SDK

The Swift SDK turns the conversation API and its event feed into one async
job: start an agent, follow its turn and return the answer.

```swift
import Fountain

let fountain = try Fountain()
let run = fountain.run(
    "Upgrade us to Phoenix 1.8 and open a PR",
    agent: "reposage",
    vault: "github-bot"
)
let result = try await run.value()

print(result.text)
print(result.url)
```

The vault value reaches the sandbox as an environment variable. It does not
enter the prompt or the event feed that the SDK reads.

The package ships a second client, `FountainKit`, for applications: the same
API read into Swift types rather than JSON. Use `Fountain` to script a run,
and `FountainKit` to build against the API. They do not share types, and an
app has no reason to use both. Everything below is `Fountain`; the typed
client has [its own section](#the-typed-client).

## Install

Add Fountain as a package dependency:

```swift
dependencies: [
    .package(
        url: "https://github.com/BinaryBourbon/fountain.git",
        from: "0.16.0"
    ),
]
```

Add the library product to your target: `Fountain` to script a run, or
`FountainKit` to build an application (it needs a release later than 0.16.0):

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Fountain", package: "fountain"),
    ]
)
```

After that release, replace the branch requirement with its version.

## Credentials

`Fountain()` uses the same credentials as the CLI. It resolves them in this
order:

```text
apiKey:  argument -> FOUNTAIN_API_KEY -> FOUNTAIN_TOKEN -> saved CLI login
baseURL: argument -> FOUNTAIN_BASE_URL -> saved CLI login -> hosted Fountain
```

Pass the API key and the base URL directly to keep the CLI credentials file
out of the process. The SDK reads that file only when an argument and the
environment both miss:

```swift
let fountain = try Fountain(
    apiKey: secret,
    baseURL: "https://fountain.example.com"
)
```

A base URL must carry a scheme and a host. `Fountain()` throws a
`FountainError` for a value such as `localhost:4000`. It does not fall back to
the hosted Fountain, because that sends your API key to a different host.

`FOUNTAIN_TOKEN` is the delegated token inside a Fountain sandbox. Code that
runs there can use `Fountain()` to start child conversations without another
credential.

## Wait for the result

`run` returns immediately with a `Run` handle. Await its `value()` when you
only need the final answer:

```swift
let run = fountain.run(prompt, agent: "reposage")
let result = try await run.value()

switch result.state {
case .done:
    print(result.text)
case .failed, .interrupted, .timeout:
    print(result.reason ?? "The turn did not finish.")
}
```

A failed agent turn is a result. A rejected request, a connection failure or
an SDK timeout throws `FountainError`.

## Stream a turn

Use `textStream` when the caller only needs the answer as it arrives:

```swift
let run = fountain.run(prompt, agent: "reposage")

for try await chunk in run.textStream {
    print(chunk, terminator: "")
}

let result = try await run.value()
```

Use `events` when the caller also needs tool use, permission requests and turn
state:

```swift
for try await event in run.events {
    switch event {
    case .text(let text):
        print(text, terminator: "")
    case .tool(let name, _):
        print("\nTool: \(name)")
    case .permission(let request, _):
        print("\nPermission needed: \(request.summary ?? request.requestID)")
    default:
        break
    }
}
```

Both streams belong to the same run. After a stream finishes, `value()`
returns the result already produced by that run.

## Continue on the same sandbox

Keep the conversation ID. A follow-up resumes the same conversation, checkout
and agent session:

```swift
let first = try await fountain
    .run("Open a pull request", agent: "reposage")
    .value()

let second = try await fountain
    .resume(first.conversationID)
    .send("Address the review comments")
    .value()

print(second.text)
```

## The typed client

`FountainKit` is the same API with the JSON resolved into types: `Agent`,
`Conversation`, `LogEvent`, `Block`, `AuthMe`, and a namespace per resource.
Errors are an enum you branch on by case and by server code. Every server
enum decodes values it does not know rather than throws. A runtime added
after you shipped does not crash your app.

```swift
import FountainKit

let client = FountainClient(config: FountainConfig(baseURL: url, apiKey: key))

for agent in try await client.agents.list() {
    print(agent.name, agent.model)
}

let run = try await client.run("Review this repository", agent: agent.id)
for try await event in run.events {
    if case .text(let chunk) = event {
        print(chunk, terminator: "")
    }
}
let result = try await run.value()
print(result.state.rawValue, result.toolsUsed)
```

`run.events` replays from the start for every subscriber, and follows the
turn once. Two views can watch one run without a second stream. A turn that
fails is a result with a state of `failed`, not a thrown error. Only
client-side failures throw.

It wraps parts of the API the untyped client does not: admin, the audit
trail, runners, API keys, `apply`, agent avatars and turn images. Use
`client.request(_:_:)` to reach what neither of them wraps.

For a worked example, [swift-goat](https://github.com/jhgaylor/swift-goat) is
a macOS app built on it.

The [TypeScript SDK](sdk.md) covers the same workflow in TypeScript. Use the
[API reference](api.md) for endpoints that need no Swift wrapper.
