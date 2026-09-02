# Changelog

Notable changes to the Fountain Swift SDK follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

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
