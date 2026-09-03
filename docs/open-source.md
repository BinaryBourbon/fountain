# Open source

Fountain is an open-source project. Managoat is one hosted instance of it.
This page says what is open, what is not, and where each thing lives.

## The names

| Name | What it is |
|---|---|
| **Fountain** | The server, the CLI, the SDKs and this manual. The name of the project. |
| **Managoat** | The instance that the maintainer runs at `managoat.com`. It runs the same code that you can run. |

The hosted instance has a different name so that "self-host Fountain" and
"use Managoat" are two clear choices. The project is not renamed.

## The licences

| Part | Licence | What it means for you |
|---|---|---|
| The server (`apps/fountain`) | [AGPL-3.0-or-later](https://github.com/BinaryBourbon/fountain/blob/main/LICENSE) | Run it, change it, host it. If you host a changed version, your users have a right to your source. |
| `ee/` (credits, Stripe and the credit emails) | [Elastic Licence 2.0](https://github.com/BinaryBourbon/fountain/blob/main/ee/LICENSE) | Free to run in your own instance. You may not offer it to third parties as a hosted service. |
| `cli/`, `sdk/typescript`, `sdk/python`, `sdk/elixir` and `sdk/swift` | [Apache-2.0](https://github.com/BinaryBourbon/fountain/blob/main/cli/LICENSE) | Build on the API or ship a client in a closed product. Keep the required license and notices when you redistribute it. |

The client parts are permissive on purpose. A connection to Fountain must
never put a licence obligation on your application.

The copyleft has one target. A company that improves Fountain and runs it as a
service owes those improvements to everyone else who runs it. The licence does
not stop a commercial host, in competition with Managoat or not. It stops a
private one.

The
[NOTICE](https://github.com/BinaryBourbon/fountain/blob/main/NOTICE) file
holds the third-party attribution.

## Where things live

| You want | Go to |
|---|---|
| The code, issues and pull requests | [github.com/BinaryBourbon/fountain](https://github.com/BinaryBourbon/fountain) |
| Your own instance | [Self-host Fountain](self-hosting.md) |
| The manual | This site, at `/docs`, on every instance. The markdown is in the repo under `docs/`. |
| The reasons behind the design | `decisions/` in the repo. The ADRs are not on this site. |
| The hosted instance | [managoat.com](https://managoat.com) |
| The CLI | `brew install BinaryBourbon/tap/fountain`, or the [CLI reference](cli.md). |
| The TypeScript SDK | `@agentshit/fountain-sdk` on npm, or the [TypeScript reference](sdk.md). |
| The Python SDK | `fountain-agent-sdk` on PyPI, or the [Python reference](python-sdk.md). |
| The Elixir SDK | [`fountain_sdk`](https://hex.pm/packages/fountain_sdk) on Hex, the [`sdk/elixir`](https://github.com/BinaryBourbon/fountain/tree/main/sdk/elixir) source, or the [Elixir reference](elixir-sdk.md). |
| The Swift SDK | The [`sdk/swift`](https://github.com/BinaryBourbon/fountain/tree/main/sdk/swift) source, or the [Swift reference](swift-sdk.md). SwiftPM reads the `Package.swift` at the repository root. |

There is no separate project website. The manual you read now is the project
site, and the repo README is its front page. One copy of each stays correct.

## What the hosted instance adds

Nothing that is not in the repo. Managoat runs the release image with the
`ee/` parts turned on, credits enabled, and the egress broker on. The
[configuration reference](configuration.md) lists every switch, so an instance
of your own can match it or not.

## To contribute

Read
[CONTRIBUTING.md](https://github.com/BinaryBourbon/fountain/blob/main/CONTRIBUTING.md) <!-- vale disable-line STE.IngForms -->
and
[CLAUDE.md](https://github.com/BinaryBourbon/fountain/blob/main/CLAUDE.md)
in the repo. The second file is the contributor guide, and coding agents read
it too.

Three prose checks run on every change to a page under `docs/`. Read
[the style sheet](https://github.com/BinaryBourbon/fountain/blob/main/standards/voice-and-style.md)
and
[the English standard](https://github.com/BinaryBourbon/fountain/blob/main/standards/simplified-technical-english.md)
before you write a page.

| Check | What it holds you to |
|---|---|
| `scripts/docs-style.py` | The house style sheet. |
| `vale lint docs` | ASD-STE100 Simplified Technical English. |
| `scripts/destink/destink.mjs` | The tells that make a page read as machine written, via the [`sentences`](https://github.com/lex00/sentences) package (MIT). |

Each check has a backlog file, and each backlog file is empty. A new page
gets all three checks from its first commit.
