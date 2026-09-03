# Fountain Swift SDK

Give an agent a computer, repositories, and credentials in one call.

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

The sandbox remains after the turn, so a follow-up continues on the same
computer and in the same agent session:

```swift
let next = fountain.resume(result.conversationID).send("Fix the worst three.")
print(try await next.value().text)
```

## Install

The remotely consumable `Package.swift` is at the repository root. Depend on
Fountain 0.16.0 or newer:

```swift
dependencies: [
    .package(url: "https://github.com/BinaryBourbon/fountain.git", from: "0.16.0")
]
```

Then add `.product(name: "Fountain", package: "fountain")` to your target.

Swift 6.1 or newer is required. The SDK supports macOS 12, iOS/tvOS 15,
watchOS 8, and Linux FoundationNetworking, with no third-party dependencies.

## Credentials

`Fountain()` resolves credentials the same way as the Fountain CLI. It throws
if the base URL it resolves has no scheme or no host:

```text
apiKey:  argument -> FOUNTAIN_API_KEY -> FOUNTAIN_TOKEN -> ~/.fountain/credentials
baseURL: argument -> FOUNTAIN_BASE_URL -> ~/.fountain/credentials -> hosted Fountain
```

Use `profile:` for another credentials-file profile. In a Fountain sandbox,
the SDK also sends `FOUNTAIN_CONVERSATION_ID` as the parent-conversation header.

## Stream a run

Every access to `events` is an independent replaying subscription to the same
run. It never starts a second API request, and a text-only stream is available.

```swift
let run = fountain.run("Review this repository", agent: "reviewer")
for try await event in run.events {
    switch event {
    case .tool(let name, _): print("->", name)
    case .text(let text): print(text, terminator: "")
    case .permission(let request, _):
        if let allow = request.options.first(where: { $0.kind == "allow_once" }) {
            try await run.answer(requestID: request.requestID, optionID: allow.optionID)
        }
    default: break
    }
}
let result = try await run.value()
```

`cancel()` only stops the SDK wait. Use `interrupt()` to stop the current turn
or `terminate()` to tear down its sandbox. Failed agent turns are successful
`RunResult` values with `.failed`; HTTP, transport, resolution, and SDK timeout
failures throw `FountainError` with a typed `kind` and retry metadata.

## Resources and the raw API

`agents`, `environments`, and `vaults` provide async list/get/create/update/
delete methods. Environments and vaults expose write-only secret helpers.
`team` provides durable teammates and schedules. Resource input uses
`JSONObject`, whose `JSONValue` values support Swift literal syntax.

```swift
let environment = try await fountain.environments.create([
    "name": "fountain-ci",
    "packages": ["apt": ["ripgrep"]]
])
try await fountain.vaults.secrets.set("github-bot", key: "GITHUB_TOKEN", value: token)

let audit = try await fountain.request("GET", "/api/audit", query: ["limit": "50"])
```

## Develop

Run from the repository root:

```bash
swift test
swift build -Xswiftc -warnings-as-errors
```
