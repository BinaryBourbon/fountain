package cmd

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/BinaryBourbon/fountain/cli/internal/acp"
	"github.com/BinaryBourbon/fountain/cli/internal/credentials"
	"github.com/BinaryBourbon/fountain/cli/internal/stream"
)

func acpTestAPI(t *testing.T, baseURL string) fountainAPI {
	t.Helper()
	t.Setenv("FOUNTAIN_BASE_URL", baseURL)
	t.Setenv("FOUNTAIN_API_KEY", "ftn_test_0000000000000000")
	return fountainAPI{
		opts: credentials.Opts{},
		log:  slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

// The server closes an SSE connection after 60 seconds of quiet, so a turn
// that thinks for longer than that WILL be disconnected mid-answer. `fountain
// run` learned this the hard way (#398); an editor session inherits the fix
// only if the ACP path actually goes through the same loop. This drives the
// real fountainAPI.Follow against a server that hangs up, and asserts the
// events either side of the break both arrive.
func TestFollowSurvivesADroppedStream(t *testing.T) {
	var (
		mu           sync.Mutex
		connections  int
		lastEventIDs []string
		queries      []string
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		connections++
		n := connections
		lastEventIDs = append(lastEventIDs, r.Header.Get("Last-Event-ID"))
		queries = append(queries, r.URL.RawQuery)
		mu.Unlock()

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Error("test server cannot flush")
			return
		}

		if n == 1 {
			// One update, then hang up mid-turn — exactly what an idle-timeout
			// close looks like from the client side.
			fmt.Fprint(w, "id: 11\nevent: output\ndata: "+
				`{"kind":"output","stream":"acp","data":"{\"jsonrpc\":\"2.0\",\"method\":\"session/update\"}"}`+
				"\n\n")
			flusher.Flush()
			return
		}

		// The reconnect: the turn finishes here.
		fmt.Fprint(w, "id: 12\nevent: stage\ndata: "+
			`{"kind":"stage","stage":"turn","state":"done","data":"{\"stop_reason\":\"end_turn\"}"}`+
			"\n\n")
		flusher.Flush()
	}))
	defer srv.Close()

	api := acpTestAPI(t, srv.URL)

	var seen []acp.Event
	err := api.Follow(context.Background(), "conv-1", "", func(ev acp.Event) (bool, error) {
		seen = append(seen, ev)
		return ev.Kind == "stage", nil
	})
	if err != nil {
		t.Fatalf("Follow: %v", err)
	}

	if connections < 2 {
		t.Fatalf("connections = %d, want the client to reconnect after the hang-up", connections)
	}
	if len(seen) != 2 {
		t.Fatalf("saw %d events, want the update and the terminal stage: %+v", len(seen), seen)
	}
	if seen[0].Stream != "acp" || seen[1].Stage != "turn" || seen[1].State != "done" {
		t.Errorf("events = %+v, want an acp update then turn/done", seen)
	}

	// Resuming from the last id is what stops the reconnect replaying the
	// whole conversation — or worse, re-forwarding updates the editor already
	// rendered.
	if lastEventIDs[0] != "" || lastEventIDs[1] != "11" {
		t.Errorf("Last-Event-ID headers = %v, want [\"\", \"11\"]", lastEventIDs)
	}

	// The filter is what keeps a runtime dialect off the wire: `stdout` is not
	// requested, so a client that cannot parse it never sees it.
	for _, q := range queries {
		if q != "streams=acp,stage" {
			t.Errorf("query = %q, want streams=acp,stage", q)
		}
	}
}

// A cancel that arrives after the turn has already ended answers 409. That is
// the ordinary outcome of a race, not a failure to report.
func TestInterruptTreats409AsAlreadyFinished(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"error":"no_turn_running"}`))
	}))
	defer srv.Close()

	api := acpTestAPI(t, srv.URL)

	if err := api.Interrupt(context.Background(), "conv-1"); err != nil {
		t.Errorf("Interrupt on a finished turn = %v, want nil", err)
	}
}

func TestInterruptReportsARealFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	api := acpTestAPI(t, srv.URL)

	if err := api.Interrupt(context.Background(), "conv-1"); err == nil {
		t.Error("Interrupt swallowed a 500")
	}
}

// A cancelled context has to end the follow rather than leave it reading a
// stream nobody is listening to — the editor has gone.
func TestFollowStopsWhenTheContextIsCancelled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	api := acpTestAPI(t, srv.URL)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if err := api.Follow(ctx, "conv-1", "", func(acp.Event) (bool, error) { return false, nil }); err == nil {
		t.Error("Follow with a cancelled context returned nil, want the context error")
	}
}

// Compile-time proof that the CLI's own follow and the ACP adapter's are the
// same loop. If they ever diverge, #398 has two places to come back.
var _ stream.Opener = streamOpener(nil)
