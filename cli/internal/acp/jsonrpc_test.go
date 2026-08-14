package acp

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// recorder is a Handler that remembers what it was asked, and answers with
// whatever the test set up.
type recorder struct {
	result   any
	err      error
	requests []string
	notifies []string
}

func (r *recorder) Request(_ context.Context, method string, _ json.RawMessage) (any, error) {
	r.requests = append(r.requests, method)
	return r.result, r.err
}

func (r *recorder) Notify(_ context.Context, method string, _ json.RawMessage) {
	r.notifies = append(r.notifies, method)
}

// serve runs one connection over a fixed input and returns the decoded output
// lines.
func serve(t *testing.T, h Handler, input string) []map[string]any {
	t.Helper()

	var out strings.Builder
	conn := NewConn(strings.NewReader(input), &out, discardLogger())
	if err := conn.Serve(context.Background(), h); err != nil {
		t.Fatalf("Serve: %v", err)
	}
	return decodeLines(t, out.String())
}

func decodeLines(t *testing.T, s string) []map[string]any {
	t.Helper()

	var msgs []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(s), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("output line is not JSON: %q: %v", line, err)
		}
		msgs = append(msgs, m)
	}
	return msgs
}

func TestRequestGetsAResponseWithTheSameID(t *testing.T) {
	h := &recorder{result: map[string]any{"ok": true}}
	out := serve(t, h, `{"jsonrpc":"2.0","id":7,"method":"initialize","params":{}}`+"\n")

	if len(out) != 1 {
		t.Fatalf("want 1 response, got %d: %v", len(out), out)
	}
	if got := out[0]["id"]; got != float64(7) {
		t.Errorf("id = %v, want 7", got)
	}
	result, ok := out[0]["result"].(map[string]any)
	if !ok || result["ok"] != true {
		t.Errorf("result = %v, want {ok:true}", out[0]["result"])
	}
}

// A string id is as legal as a numeric one, and echoing it back as a number
// (or as a quoted number) breaks correlation on the client.
func TestRequestIDIsEchoedVerbatim(t *testing.T) {
	h := &recorder{result: map[string]any{}}
	out := serve(t, h, `{"jsonrpc":"2.0","id":"abc-1","method":"initialize"}`+"\n")

	if got := out[0]["id"]; got != "abc-1" {
		t.Errorf("id = %#v, want \"abc-1\"", got)
	}
}

// JSON-RPC forbids responding to a notification. An editor that receives a
// response it never asked for has an orphan in its correlation table.
func TestNotificationGetsNoResponse(t *testing.T) {
	h := &recorder{result: map[string]any{"ok": true}}
	out := serve(t, h, `{"jsonrpc":"2.0","method":"session/cancel","params":{}}`+"\n")

	if len(out) != 0 {
		t.Fatalf("want no output for a notification, got %v", out)
	}
	if len(h.notifies) != 1 || h.notifies[0] != "session/cancel" {
		t.Errorf("notifies = %v, want [session/cancel]", h.notifies)
	}
	if len(h.requests) != 0 {
		t.Errorf("a notification was dispatched as a request: %v", h.requests)
	}
}

func TestHandlerErrorBecomesAJSONRPCError(t *testing.T) {
	h := &recorder{err: Errorf(CodeMethodNotFound, "method not found: nope")}
	out := serve(t, h, `{"jsonrpc":"2.0","id":1,"method":"nope"}`+"\n")

	errObj, ok := out[0]["error"].(map[string]any)
	if !ok {
		t.Fatalf("want an error object, got %v", out[0])
	}
	if errObj["code"] != float64(CodeMethodNotFound) {
		t.Errorf("code = %v, want %d", errObj["code"], CodeMethodNotFound)
	}
	if _, hasResult := out[0]["result"]; hasResult {
		t.Error("an error response must not also carry a result")
	}
}

// A plain error is not a protocol error, and leaking it as one (or as a
// crash) tells the editor something false about whose fault it was.
func TestPlainErrorBecomesAnInternalError(t *testing.T) {
	h := &recorder{err: io.ErrUnexpectedEOF}
	out := serve(t, h, `{"jsonrpc":"2.0","id":1,"method":"initialize"}`+"\n")

	errObj := out[0]["error"].(map[string]any)
	if errObj["code"] != float64(CodeInternalError) {
		t.Errorf("code = %v, want %d", errObj["code"], CodeInternalError)
	}
	if !strings.Contains(errObj["message"].(string), "unexpected EOF") {
		t.Errorf("message = %v, want it to carry the underlying error", errObj["message"])
	}
}

// The server peer made the same call for the same reason: adapters print
// deprecation notices and stack traces onto pipes that are supposed to carry
// only protocol. Killing the connection over somebody else's diagnostic would
// end a working session.
func TestGarbageLineIsSkippedAndTheNextMessageStillAnswers(t *testing.T) {
	h := &recorder{result: map[string]any{}}
	input := "npm warn deprecated something@1.0.0\n" +
		`{"jsonrpc":"2.0","id":2,"method":"initialize"}` + "\n"

	out := serve(t, h, input)

	if len(out) != 1 || out[0]["id"] != float64(2) {
		t.Fatalf("want one response to id 2, got %v", out)
	}
}

func TestBlankLinesAreIgnored(t *testing.T) {
	h := &recorder{result: map[string]any{}}
	out := serve(t, h, "\n\n"+`{"jsonrpc":"2.0","id":1,"method":"initialize"}`+"\n\n")

	if len(out) != 1 {
		t.Fatalf("want 1 response, got %d: %v", len(out), out)
	}
}

// An editor closing the pipe is how a session ends. It is not a failure, and
// a non-zero exit turns every normal shutdown into a bug report.
func TestClosedStdinIsACleanExit(t *testing.T) {
	conn := NewConn(strings.NewReader(""), &strings.Builder{}, discardLogger())
	if err := conn.Serve(context.Background(), &recorder{}); err != nil {
		t.Errorf("Serve on empty input = %v, want nil", err)
	}
}

// A final message with no trailing newline still has to be answered — some
// clients do not terminate the last line before closing the pipe.
func TestUnterminatedFinalLineIsStillHandled(t *testing.T) {
	h := &recorder{result: map[string]any{}}
	out := serve(t, h, `{"jsonrpc":"2.0","id":3,"method":"initialize"}`)

	if len(out) != 1 || out[0]["id"] != float64(3) {
		t.Fatalf("want a response to id 3, got %v", out)
	}
}

func TestCancelledContextStopsServing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	conn := NewConn(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`+"\n"), &strings.Builder{}, discardLogger())
	if err := conn.Serve(ctx, &recorder{}); err != nil {
		t.Errorf("Serve with a cancelled context = %v, want nil", err)
	}
}

// Responses and forwarded session/update notifications are written by
// different goroutines. Two interleaved writes produce one unparseable line,
// which an editor reports as the agent crashing.
func TestConcurrentWritesProduceWholeLines(t *testing.T) {
	out := &splittingWriter{}
	conn := NewConn(strings.NewReader(""), out, discardLogger())

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			conn.Notify("session/update", map[string]any{"n": i, "pad": strings.Repeat("x", 512)})
		}(i)
	}
	wg.Wait()

	lines := decodeLines(t, out.String())
	if len(lines) != 50 {
		t.Fatalf("want 50 whole lines, got %d", len(lines))
	}
}

// splittingWriter is the test's stand-in for a pipe that does not deliver a
// Write atomically: it splits every write in two and yields in between. A
// writer that locked for the whole call would serialise on its own behalf and
// the test would pass with Conn's mutex removed — proving nothing.
type splittingWriter struct {
	mu sync.Mutex
	b  strings.Builder
}

func (w *splittingWriter) Write(p []byte) (int, error) {
	half := len(p) / 2
	w.append(p[:half])
	runtime.Gosched()
	w.append(p[half:])
	return len(p), nil
}

func (w *splittingWriter) append(p []byte) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.b.Write(p)
}

func (w *splittingWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.String()
}
