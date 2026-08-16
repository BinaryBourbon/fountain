// Command buzz-backend-fountain is the Buzz remote-agents provider that runs a
// Buzz agent as a hosted Fountain agent (ADR 0020 Phase 3, #738).
//
// It is not run by hand: Buzz's desktop discovers it by name (buzz-backend-*),
// spawns it once per operation, writes one JSON request on stdin, and reads one
// JSON response on stdout. A nonzero exit means only that the request could not
// be read; every other failure is reported in-band as {"ok":false,"error":…}.
//
// Fountain credentials come from the environment or the fountain CLI creds file
// (FOUNTAIN_API_KEY / FOUNTAIN_BASE_URL) — never from provider_config, which the
// desktop refuses to carry secrets in.
package main

import (
	"encoding/json"
	"io"
	"os"

	"github.com/BinaryBourbon/fountain/cli/internal/api"
	"github.com/BinaryBourbon/fountain/cli/internal/backend"
	"github.com/BinaryBourbon/fountain/cli/internal/credentials"
)

func main() {
	in, err := io.ReadAll(os.Stdin)
	if err != nil {
		// Could not read the request at all — the one nonzero-exit case.
		os.Exit(1)
	}

	var req backend.Request
	if err := json.Unmarshal(in, &req); err != nil {
		writeOut(backend.DeployResponse{OK: false, Error: "invalid request json"})
		return
	}

	switch req.Op {
	case "info":
		writeOut(backend.Info())
	case "deploy":
		f := backend.NewFountain(api.New(credentials.Opts{}))
		writeOut(backend.Deploy(req, f))
	default:
		writeOut(backend.DeployResponse{OK: false, Error: "unknown op: " + req.Op})
	}
}

func writeOut(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"ok":false,"error":"could not encode response"}`)
	}
	os.Stdout.Write(b)
	os.Stdout.Write([]byte("\n"))
}
