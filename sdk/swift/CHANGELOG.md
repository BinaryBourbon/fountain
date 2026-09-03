# Changelog

Notable changes to the Fountain Swift SDK follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- `FountainKit`, a second product in this package: the same API with
  `Codable` models, a namespace per resource, a `FountainError` enum, typed
  SSE (`LogEvent`/`Block`), a `TurnFollower` and a `Run` whose event stream
  replays from the beginning for every subscriber. It wraps admin, audit,
  runners, API keys and `apply`, which the untyped client leaves to its
  escape hatch. Contributed from swift-goat, where it grew as that app's
  client, and relicensed to Apache-2.0 by its author (ADR 0041).
- `FountainKit` runs the shared conformance suite as the `swift-kit` column,
  green on all 24 scenarios — including the timeout scenario `swift` skips
  (#1424), because it raises before re-reading the conversation.

## [0.16.0] - 2026-09-03

### Added

- Initial dependency-free Swift SDK with async run streaming, resumable
  conversations, permission answers, typed errors, resource CRUD, teammates,
  schedules, sandbox reads, global/team event feeds, and a raw API escape hatch.
- SwiftPM package metadata at the repository root for remote consumption.
- Linux-compatible incremental SSE transport with automatic cursor resume.
- Event streams that stay idle until they are iterated, so building one does
  not open a connection or buffer events the caller has not asked for.
- Construction that throws for a base or app URL with no scheme or no host,
  instead of falling back to the hosted deployment and sending the API key to
  a host the caller never named.
- Credentials-file reads only when an argument and the environment both miss.

### Changed

- Swift 6.1 is now both the declared package tools version and the minimum
  compiler version. The SSE iterator is safe under Swift 6 strict concurrency.
- The Fountain release pipeline resolves and builds the tagged package from a
  clean consumer before it creates the GitHub Release.
