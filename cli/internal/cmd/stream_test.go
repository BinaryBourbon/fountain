package cmd

import (
	"context"
	"errors"
	"io"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeStream serves a scripted sequence of connections. Each entry is the body
// one connection produces before returning io.EOF, which is exactly what the
// server does when it closes an idle SSE loop after 60 seconds of quiet.
type fakeStream struct {
	mu       sync.Mutex
	bodies   []string
	opened   int
	resumeAt []string // Last-Event-ID seen on each open
	failNext int      // number of leading opens that should fail
	openErr  error
}

func (f *fakeStream) open(_ context.Context, lastEventID string) (io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.resumeAt = append(f.resumeAt, lastEventID)
	f.opened++

	if f.failNext > 0 {
		f.failNext--
		return nil, f.openErr
	}
	if len(f.bodies) == 0 {
		// Nothing left to serve: behave like a stream that closes immediately.
		return io.NopCloser(strings.NewReader("")), nil
	}
	body := f.bodies[0]
	f.bodies = f.bodies[1:]
	return io.NopCloser(strings.NewReader(body)), nil
}

func (f *fakeStream) opens() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.opened
}

func (f *fakeStream) resumeIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]string, len(f.resumeAt))
	copy(out, f.resumeAt)
	return out
}

func stage(id int, stageName, state string) string {
	return "id: " + strconv.Itoa(id) + "\nevent: stage\ndata: {\"stage\":\"" + stageName +
		"\",\"state\":\"" + state + "\"}\n\n"
}

// TestReconnectsAfterServerClosesIdleStream is the regression this change
// exists for. The old loop returned nil on io.EOF, so a turn that thought for
// longer than the server's 60s idle window made `fountain run` exit reporting
// success while the agent was still working.
func TestReconnectsAfterServerClosesIdleStream(t *testing.T) {
	f := &fakeStream{bodies: []string{
		// First connection: some progress, then the server closes.
		stage(1, "provision", "done"),
		// Second connection: the turn actually finishes.
		stage(2, "turn", "done"),
	}}

	if err := followStream(f.open, time.Second, "conv-1"); err != nil {
		t.Fatalf("expected clean completion, got %v", err)
	}
	if f.opens() != 2 {
		t.Fatalf("expected the stream to be reopened after EOF, opened %d times", f.opens())
	}
}

func TestResumesFromLastEventID(t *testing.T) {
	f := &fakeStream{bodies: []string{
		stage(7, "setup", "done"),
		stage(8, "turn", "done"),
	}}

	if err := followStream(f.open, time.Second, "conv-1"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got := f.resumeIDs()
	if len(got) != 2 {
		t.Fatalf("expected 2 opens, got %v", got)
	}
	if got[0] != "" {
		t.Errorf("first open should not resume, sent Last-Event-ID %q", got[0])
	}
	// Without this the replay restarts from zero and output already seen is
	// printed twice, or output produced while disconnected is lost.
	if got[1] != "7" {
		t.Errorf("reconnect should resume from the last event id, sent %q", got[1])
	}
}

func TestStopsOnTurnDone(t *testing.T) {
	f := &fakeStream{bodies: []string{stage(1, "turn", "done")}}

	if err := followStream(f.open, time.Second, "conv-1"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if f.opens() != 1 {
		t.Fatalf("should not reconnect after a terminal event, opened %d times", f.opens())
	}
}

// A failed provision means no turn is ever coming. Reconnecting would just wait
// out the idle timeout.
func TestStopsOnProvisionFailed(t *testing.T) {
	f := &fakeStream{bodies: []string{stage(1, "provision", "failed")}}

	if err := followStream(f.open, time.Second, "conv-1"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if f.opens() != 1 {
		t.Fatalf("expected to stop on provision failure, opened %d times", f.opens())
	}
}

func TestStopsOnTerminated(t *testing.T) {
	f := &fakeStream{bodies: []string{stage(1, "terminate", "done")}}

	if err := followStream(f.open, time.Second, "conv-1"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if f.opens() != 1 {
		t.Fatalf("expected to stop on terminate, opened %d times", f.opens())
	}
}

// The old code reported success here. Silence must be an explicit, actionable
// error instead — "your turn may still be running" is very different from
// "your turn finished".
func TestIdleTimeoutIsAnErrorNotSilentSuccess(t *testing.T) {
	blocked := &blockingStream{released: make(chan struct{})}
	defer close(blocked.released)

	err := followStream(blocked.open, 100*time.Millisecond, "conv-42")
	if err == nil {
		t.Fatal("an idle stream must not report success")
	}
	if !strings.Contains(err.Error(), "conv-42") {
		t.Errorf("error should tell the user how to reattach, got %q", err)
	}
	if !strings.Contains(err.Error(), "still be running") {
		t.Errorf("error should say the turn may still be running, got %q", err)
	}
}

func noBackoff(t *testing.T) {
	t.Helper()
	original := reconnectBackoff
	reconnectBackoff = func(int) time.Duration { return 0 }
	t.Cleanup(func() { reconnectBackoff = original })
}

func TestGivesUpAfterRepeatedOpenFailures(t *testing.T) {
	noBackoff(t)
	f := &fakeStream{failNext: 99, openErr: errors.New("connection refused")}

	err := followStream(f.open, time.Second, "conv-1")
	if err == nil {
		t.Fatal("expected an error once reconnects are exhausted")
	}
	if !strings.Contains(err.Error(), "connection refused") {
		t.Errorf("error should preserve the cause, got %q", err)
	}
	if f.opens() != maxReconnectAttempts {
		t.Errorf("expected %d attempts, got %d", maxReconnectAttempts, f.opens())
	}
}

func TestRecoversFromATransientOpenFailure(t *testing.T) {
	noBackoff(t)
	f := &fakeStream{
		failNext: 1,
		openErr:  errors.New("temporary failure"),
		bodies:   []string{stage(1, "turn", "done")},
	}

	if err := followStream(f.open, time.Second, "conv-1"); err != nil {
		t.Fatalf("a single transient failure should not be fatal, got %v", err)
	}
}

func TestStreamIdleTimeoutOverride(t *testing.T) {
	t.Setenv("FOUNTAIN_STREAM_IDLE_TIMEOUT", "5")
	if got := streamIdleTimeout(); got != 5*time.Second {
		t.Errorf("want 5s from env, got %s", got)
	}

	t.Setenv("FOUNTAIN_STREAM_IDLE_TIMEOUT", "not-a-number")
	if got := streamIdleTimeout(); got != defaultStreamIdle {
		t.Errorf("garbage should fall back to the default, got %s", got)
	}
}

// blockingStream never produces bytes and never closes, which is what a stalled
// connection looks like from the client's side.
type blockingStream struct{ released chan struct{} }

func (b *blockingStream) open(ctx context.Context, _ string) (io.ReadCloser, error) {
	return &blockingBody{ctx: ctx, released: b.released}, nil
}

type blockingBody struct {
	ctx      context.Context
	released chan struct{}
}

func (b *blockingBody) Read(_ []byte) (int, error) {
	select {
	case <-b.ctx.Done():
		return 0, b.ctx.Err()
	case <-b.released:
		return 0, io.EOF
	}
}

func (b *blockingBody) Close() error { return nil }
