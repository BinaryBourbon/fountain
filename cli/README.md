# Fountain CLI (Go)

Single-binary port of the Fountain CLI from Elixir/Burrito to Go. Same
command surface, same API contract, same `~/.fountain/credentials` file.

## Why a port

The CLI is an HTTP/JSON client with subprocess shellouts (1Password,
Bitwarden Secrets Manager, Infisical) and an SSE stream consumer. None
of that needs the BEAM. Burrito wraps Elixir releases in a Zig-built
launcher so the BEAM ships inside the binary; that pipeline has been
fragile (Zig version pinning, slow startup, large binaries) and the
runtime concurrency model adds nothing for a CLI.

The Go binary is ~10 MB, statically linked, starts in <50 ms, and
cross-compiles cleanly with stdlib tooling.

## Build

Requires Go 1.25+.

```sh
cd cli
go build -o fountain ./cmd/fountain
./fountain --help
```

Cross-compile:

```sh
GOOS=linux  GOARCH=amd64 CGO_ENABLED=0 go build -o fountain-linux-amd64  ./cmd/fountain
GOOS=linux  GOARCH=arm64 CGO_ENABLED=0 go build -o fountain-linux-arm64  ./cmd/fountain
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -o fountain-darwin-amd64 ./cmd/fountain
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o fountain-darwin-arm64 ./cmd/fountain
```

The `cli-release-go.yml` workflow builds and attaches all four to the
GitHub release on tag push.

## Layout

```
cli/
  cmd/fountain/         entry point
  internal/
    api/                HTTP client (Bearer auth, JSON, error envelope)
    cmd/                Cobra command tree (auth, keys, env, agent, vault, conv, run, apply)
    config/             API key + base URL precedence resolver
    credentials/        ~/.fountain/credentials reader/writer (TOML-ish)
    manifest/           YAML doc reader for `apply`
    output/             table + JSON rendering helpers
    secrets/            external secret resolvers (op, bws, infisical)
    sse/                RFC 6202 Server-Sent Events parser
    substitution/       ${VAR} expansion (with $${VAR} escape)
```

## Test

```sh
go test ./...
```

Coverage focuses on the pure logic — credentials parser, substitution,
SSE framing, manifest loading. Command handlers (which only assemble
HTTP requests) are validated by smoke runs against a real server.

## Parity with the Elixir CLI

Every command and flag from `apps/fountain_cli/` is supported, with one
explicit omission: the `up` / `down` self-deploy commands were removed
from the Elixir CLI in [phase-3-cli](../plan/phase-3-cli/engineer-brief.md)
and are not reintroduced here.

## Migration plan

1. **This PR** — Go CLI lives in `cli/`, Elixir CLI continues to ship
   alongside it. Both release workflows run on tag push.
2. **Validation** — Cut a tag, smoke-test the Go binary against the
   production API for a few days.
3. **Follow-up PR** — Delete `apps/fountain_cli/`, drop Burrito and
   `release.yml`, rename `cli-release-go.yml` → `release.yml`, update
   docs that point at the Burrito artifacts.
